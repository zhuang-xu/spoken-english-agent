"""Decode learner recordings, call Azure Speech, and preserve measured turn evidence."""
import base64
import io
import json
import logging
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
import wave

import av
import httpx
from fastapi import HTTPException
from app.schemas import SpeechAssessment, SpeechSegment, SpeechWord, SpeechPhoneme
from app.storage.speech import load_audio, speech_cache

SPEECH_BUDGET_SECONDS = 120.0
MAX_AUDIO_SECONDS = 600
FORMATS = {'audio/webm': 'matroska', 'audio/ogg': 'ogg', 'audio/wav': 'wav',
           'audio/mp4': 'mov', 'audio/mpeg': 'mp3'}
REST_CHUNK_SECONDS = 25


def decode_audio(audio, media_type, deadline):
    """Decode actual bytes and preserve internal silence; never trust declared timing."""
    pcm = bytearray()
    try:
        with av.open(io.BytesIO(audio), format=FORMATS[media_type.split(';')[0].strip()],
                     options={'protocol_whitelist': ''}) as source:
            if len(source.streams.audio) != 1 or source.streams.video:
                raise ValueError('Expected one audio stream')
            resampler = av.AudioResampler(format='s16', layout='mono', rate=16000)
            for frame in source.decode(audio=0):
                if time.monotonic() >= deadline:
                    raise HTTPException(504, 'Speech assessment timed out.')
                for normalized in resampler.resample(frame):
                    pcm.extend(bytes(normalized.planes[0])[:normalized.samples * 2])
                if len(pcm) > MAX_AUDIO_SECONDS * 32000:
                    raise HTTPException(413, 'Learner recording exceeds ten minutes.')
            for normalized in resampler.resample(None):
                pcm.extend(bytes(normalized.planes[0])[:normalized.samples * 2])
    except (av.error.FFmpegError, ValueError, KeyError, EOFError):
        raise HTTPException(422, 'Learner recording cannot be decoded as supported audio.') from None
    if not pcm:
        raise HTTPException(422, 'Learner recording contains no audio samples.')
    if len(pcm) > MAX_AUDIO_SECONDS * 32000:
        raise HTTPException(413, 'Learner recording exceeds ten minutes.')
    return bytes(pcm)


def recognize_audio(pcm, settings, timeout):
    """Hard timeout covers SDK startup, recognition and cleanup; keys stay out of argv."""
    if timeout <= 0:
        raise HTTPException(504, 'Speech assessment timed out.')
    transport = os.environ.get(
        'SPEECH_ASSESSMENT_TRANSPORT', 'rest' if os.environ.get('WEBSITE_HOSTNAME') else 'sdk')
    if transport == 'rest':
        return recognize_audio_rest(pcm, settings, timeout)
    env = os.environ.copy()
    env['AZURE_SPEECH_KEY'] = settings.azure_speech_key.get_secret_value()
    env['AZURE_SPEECH_REGION'] = settings.azure_speech_region
    env['PYTHONPATH'] = str(Path(__file__).resolve().parents[2])
    try:
        completed = subprocess.run(
            [sys.executable, '-m', 'app.services.speech_worker'], input=pcm,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(504, 'Speech assessment timed out.') from None
    except OSError:
        raise HTTPException(503, 'Speech runtime is unavailable.') from None
    try:
        payload = json.loads(completed.stdout)
        if completed.returncode or not isinstance(payload, dict) or not isinstance(payload.get('segments'), list):
            raise ValueError('Invalid speech result')
        return payload['segments']
    except (ValueError, TypeError):
        raise HTTPException(502, 'Speech provider could not assess this recording.') from None


def recognize_audio_rest(pcm, settings, timeout):
    """Use short-audio REST chunks when a managed host lacks Speech SDK libraries."""
    header = base64.b64encode(json.dumps({
        'ReferenceText': '', 'GradingSystem': 'HundredMark', 'Granularity': 'Phoneme',
        'Dimension': 'Comprehensive', 'EnableMiscue': 'False',
        'EnableProsodyAssessment': 'True',
    }, separators=(',', ':')).encode()).decode()
    url = (f'https://{settings.azure_speech_region}.stt.speech.microsoft.com/'
           'speech/recognition/conversation/cognitiveservices/v1')
    chunk_bytes = REST_CHUNK_SECONDS * 32000
    started = time.monotonic()
    results = []
    for byte_offset in range(0, len(pcm), chunk_bytes):
        remaining = timeout - (time.monotonic() - started)
        if remaining <= 0:
            raise HTTPException(504, 'Speech assessment timed out.')
        output = io.BytesIO()
        with wave.open(output, 'wb') as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(pcm[byte_offset:byte_offset + chunk_bytes])
        try:
            response = httpx.post(
                url, params={'language': 'en-US', 'format': 'detailed', 'profanity': 'raw'},
                headers={'Ocp-Apim-Subscription-Key': settings.azure_speech_key.get_secret_value(),
                         'Pronunciation-Assessment': header, 'Accept': 'application/json',
                         'Content-Type': 'audio/wav; codecs=audio/pcm; samplerate=16000'},
                content=output.getvalue(), timeout=min(30.0, remaining))
            response.raise_for_status()
            payload = response.json()
        except httpx.TimeoutException:
            raise HTTPException(504, 'Speech assessment timed out.') from None
        except (httpx.HTTPError, ValueError, TypeError):
            raise HTTPException(502, 'Speech provider could not assess this recording.') from None
        status = payload.get('RecognitionStatus') if isinstance(payload, dict) else None
        if status in {'NoMatch', 'InitialSilenceTimeout', 'BabbleTimeout'}:
            continue
        if status != 'Success' or not isinstance(payload.get('NBest'), list) or not payload['NBest']:
            raise HTTPException(502, 'Speech provider returned invalid assessment data.')
        offset_ticks = byte_offset / 32000 * 10_000_000
        payload['Offset'] = float(payload.get('Offset', 0)) + offset_ticks
        for hypothesis in payload['NBest']:
            for word in hypothesis.get('Words', []):
                word['Offset'] = float(word.get('Offset', 0)) + offset_ticks
        results.append(payload)
    return results


def parse_assessment(raw, reference, duration_ms):
    segments = []
    for result in raw:
        if result['RecognitionStatus'] != 'Success':
            raise ValueError('Incomplete speech recognition')
        hypothesis = result['NBest'][0]
        scores = hypothesis.get('PronunciationAssessment', hypothesis)
        words = []
        for word in hypothesis['Words']:
            pronunciation = word.get('PronunciationAssessment', word)
            words.append(SpeechWord(
                word=word['Word'], offset_ms=word['Offset'] / 10000,
                duration_ms=word['Duration'] / 10000,
                accuracy_score=pronunciation['AccuracyScore'], error_type=pronunciation['ErrorType'],
                phonemes=[SpeechPhoneme(phoneme=p['Phoneme'],
                                       accuracy_score=p.get('PronunciationAssessment', p)['AccuracyScore'])
                          for p in word.get('Phonemes', [])]))
        segment = SpeechSegment(
            text=hypothesis['Display'], offset_ms=result['Offset'] / 10000,
            duration_ms=result['Duration'] / 10000, accuracy_score=scores['AccuracyScore'],
            fluency_score=scores['FluencyScore'], prosody_score=scores.get('ProsodyScore'), words=words)
        if not segment.text.strip() or not words or segment.offset_ms + segment.duration_ms > duration_ms + 100:
            raise ValueError('Invalid speech segment')
        for word in words:
            if (not word.word.strip() or word.offset_ms < segment.offset_ms - 100
                    or word.offset_ms + word.duration_ms > segment.offset_ms + segment.duration_ms + 100):
                raise ValueError('Invalid word timing')
        segments.append(segment)
    segments.sort(key=lambda s: s.offset_ms)
    if any(a.offset_ms + a.duration_ms > b.offset_ms + 100 for a, b in zip(segments, segments[1:])):
        raise ValueError('Overlapping speech segments')
    reason = ('no_recognized_speech' if not segments else
              'too_few_words' if sum(len(s.words) for s in segments) < 5 else None)
    return SpeechAssessment(turn_id=reference['turn_id'], audio_sha256=reference['sha256'],
                            status='insufficient_evidence' if reason else 'assessed', reason=reason,
                            duration_ms=duration_ms, segments=[] if reason else segments)


def assess_snapshot(snapshot, session_id, settings):
    refs = json.loads(snapshot).get('audio_references', [])
    results = []
    deadline = time.monotonic() + SPEECH_BUDGET_SECONDS
    for reference in refs:
        try:
            saved = speech_cache(settings.database_path, session_id, reference)
            if saved is not None:
                results.append(saved)
                continue
            audio = load_audio(settings.database_path, session_id, reference)
        except (sqlite3.Error, OSError):
            raise HTTPException(503, 'Speech assessment storage is unavailable.') from None
        if (not settings.azure_speech_key.get_secret_value()
                or not re.fullmatch(r'[a-z][a-z0-9-]{1,49}', settings.azure_speech_region)):
            raise HTTPException(503, 'Azure Speech is not configured correctly.')
        pcm = decode_audio(audio, reference['media_type'], deadline)
        duration_ms = len(pcm) / 32
        if duration_ms < 3000:
            assessment = SpeechAssessment(turn_id=reference['turn_id'], audio_sha256=reference['sha256'],
                status='insufficient_evidence', reason='too_short', duration_ms=duration_ms)
        else:
            try:
                raw = recognize_audio(pcm, settings, deadline - time.monotonic())
                assessment = parse_assessment(raw, reference, duration_ms)
            except HTTPException as error:
                if error.status_code not in {502, 503, 504}:
                    raise
                logging.getLogger('spoken.evaluation').warning(
                    'speech_assessment_unavailable status=%s', error.status_code)
                assessment = SpeechAssessment(
                    turn_id=reference['turn_id'], audio_sha256=reference['sha256'],
                    status='unavailable', reason='provider_unavailable', duration_ms=duration_ms)
            except (ValueError, TypeError, KeyError, IndexError, AttributeError):
                logging.getLogger('spoken.evaluation').warning(
                    'speech_assessment_unavailable status=invalid_result')
                assessment = SpeechAssessment(
                    turn_id=reference['turn_id'], audio_sha256=reference['sha256'],
                    status='unavailable', reason='provider_unavailable', duration_ms=duration_ms)
        try:
            if assessment.status == 'unavailable':
                results.append(assessment)
            else:
                results.append(speech_cache(settings.database_path, session_id, reference, assessment))
        except (sqlite3.Error, OSError):
            raise HTTPException(503, 'Speech assessment storage is unavailable.') from None
    return results


def speech_context(assessments):
    """Bound model input, while detailed evidence stays in the stored API response."""
    turns = []
    segments = []
    practice_words = []
    seen_words = set()
    for assessment in assessments[:50]:
        segments.extend(assessment.segments[:5])
        for segment in assessment.segments[:5]:
            for word in sorted(segment.words, key=lambda item: item.accuracy_score):
                if word.error_type == 'None' and word.accuracy_score >= 70:
                    continue
                key = word.word.casefold()
                if key not in seen_words:
                    seen_words.add(key)
                    practice_words.append({'word': word.word[:100],
                                           'accuracy': word.accuracy_score,
                                           'error_type': word.error_type[:100]})
        turns.append({'turn_id': assessment.turn_id, 'status': assessment.status, 'reason': assessment.reason,
                      'segment_count': len(assessment.segments),
                      'segments': [{'offset_ms': s.offset_ms, 'accuracy': s.accuracy_score,
                                    'fluency': s.fluency_score, 'prosody': s.prosody_score,
                                    'word_examples': [{'word': w.word[:100], 'accuracy': w.accuracy_score,
                                                       'error_type': w.error_type[:100]}
                                                      for w in s.words if w.error_type != 'None'][:5]}
                                   for s in assessment.segments[:5]]})
    average = lambda values: round(sum(values) / len(values)) if values else None
    assessed_turns = sum(item.status == 'assessed' for item in assessments)
    overview = {
        'assessed_turns': assessed_turns,
        'total_turns': len(assessments),
        'assessed_segments': len(segments),
        'average_pronunciation': average([item.accuracy_score for item in segments]),
        'average_spoken_fluency': average([item.fluency_score for item in segments]),
        'average_rhythm_and_intonation': average(
            [item.prosody_score for item in segments if item.prosody_score is not None]),
        'practice_words': practice_words[:3],
    }
    return {'source': 'Azure Speech', 'locale': 'en-US', 'total_turns': len(assessments),
            'overview': overview,
            'note': 'Preview: first 50 turns, first 5 segments and up to 5 flagged words per segment. '
                    'Overview values are arithmetic means across previewed assessed segments. '
                    'Scores describe only assessed segments; do not infer whole-session proficiency.',
            'turns': turns}

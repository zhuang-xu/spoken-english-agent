import base64
import io
import json
import sqlite3
import subprocess
import time
from uuid import uuid4

import av
import httpx
import pytest
from fastapi import HTTPException
from pydantic import SecretStr

from app.services.pronunciation import decode_audio, parse_assessment, recognize_audio, recognize_audio_rest
from app.storage.evaluations import evaluation_record, finish_evaluation


def finish_speech_session(learner_turn, learner_wav, mock_openai_post,
                          evaluation_response, synthesis_response):
    """Upload configured audio now, then build the final text-evaluation snapshot."""
    api, settings, base, transcript = learner_turn
    sid, turn = base.split('/')[2], base.split('/')[-1]
    settings.azure_speech_key = SecretStr('speech-secret')
    settings.azure_speech_region = 'eastus'
    settings.azure_openai_evaluation_deployment = 'test-evaluation'
    api.put(base + '/transcript', json=transcript).raise_for_status()
    upload = api.put(base + '/audio', content=learner_wav, headers={'Content-Type': 'audio/wav'})
    api.post(f'/sessions/{sid}/end').raise_for_status()
    api.put(f'/sessions/{sid}/upload-manifest', json={
        'audio_turn_ids': [turn], 'transcript_turn_ids': [turn],
        'agent_transcripts': []}).raise_for_status()
    mock_openai_post.reset_mock()
    mock_openai_post.side_effect = [evaluation_response, synthesis_response]
    return api, settings, f'/sessions/{sid}/evaluation', upload


def test_combined_evaluation(ready_speech_evaluation, mock_speech_process, mock_openai_post):
    api, settings, url = ready_speech_evaluation
    response = api.post(url)
    assert response.status_code == 201, response.text
    result = response.json()
    assert result['rubric_version'] == 'staged-coaching-v4'
    assert result['transcript_status'] == result['final_status'] == 'completed'
    assert result['speech_status'] == 'completed'
    assert result['transcript_result'] is not None
    assert result['not_assessed'] == []
    assert result['speech_summary'] == {
        'assessed_turns': 1, 'total_turns': 1, 'assessed_segments': 1,
        'average_pronunciation': 85, 'average_spoken_fluency': 80,
        'average_rhythm_and_intonation': 75,
    }
    assessment = result['speech_assessments'][0]
    assert assessment['status'] == 'assessed'
    assert assessment['duration_ms'] == 4000
    segment = assessment['segments'][0]
    assert segment['accuracy_score'] == 85
    assert segment['fluency_score'] == 80
    assert segment['prosody_score'] == 75
    assert segment['words'][1]['offset_ms'] == 600
    assert segment['words'][0]['phonemes'][0]['accuracy_score'] == 85
    assert api.get(url).json() == result
    assert api.post(url).json() == result
    assert mock_speech_process.call_count == 1
    assert mock_openai_post.call_count == 2
    call = mock_speech_process.call_args
    assert call.args[0][-1] == 'app.services.speech_worker'
    assert 'speech-secret' not in str(call.args)
    assert call.kwargs['env']['AZURE_SPEECH_KEY'] == 'speech-secret'
    assert call.kwargs['env']['AZURE_SPEECH_REGION'] == 'eastus'
    assert len(call.kwargs['input']) == 128000
    assert 0 < call.kwargs['timeout'] <= 120
    context = json.loads(mock_openai_post.call_args.kwargs['json']['messages'][1]['content'])
    assert context['speech_findings']['turns'][0]['segments'][0]['accuracy'] == 85
    assert context['speech_findings']['overview'] == {
        'assessed_turns': 1, 'total_turns': 1, 'assessed_segments': 1,
        'average_pronunciation': 85, 'average_spoken_fluency': 80,
        'average_rhythm_and_intonation': 75, 'practice_words': [],
    }
    assert 'speech-secret' not in json.dumps(context) + response.text
    with sqlite3.connect(settings.database_path) as db:
        snapshot, record = db.execute('SELECT snapshot, record FROM session_evaluations').fetchone()
        cache = db.execute('SELECT result FROM speech_assessments').fetchone()[0]
    assert 'speech-secret' not in snapshot + record + cache
    assert 'audio_references' in snapshot


def test_speech_cached_when_text_fails(ready_speech_evaluation, mock_speech_process,
                                      mock_openai_post, evaluation_response, synthesis_response):
    api, settings, url = ready_speech_evaluation
    mock_openai_post.side_effect = httpx.ReadTimeout('private')
    assert api.post(url).status_code == 504
    assert api.get(url).json()['status'] == 'failed'
    mock_openai_post.side_effect = [evaluation_response, synthesis_response]
    settings.azure_speech_key = SecretStr('')
    assert api.post(url).status_code == 201
    assert mock_speech_process.call_count == 1


def test_transcript_finishes_while_last_speech_turn_is_pending(
        ready_speech_evaluation, learner_wav, mock_speech_process, mock_openai_post):
    api, settings, url = ready_speech_evaluation
    sid = url.split('/')[2]
    with sqlite3.connect(settings.database_path) as db:
        turn = db.execute('SELECT turn_id FROM learner_turns WHERE session_id=?', (sid,)).fetchone()[0]
        db.execute('DELETE FROM speech_assessments WHERE session_id=?', (sid,))

    waiting = api.post(url)
    assert waiting.status_code == 202
    assert waiting.headers['retry-after'] == '5'
    state = waiting.json()
    assert state['status'] == 'waiting'
    assert state['transcript_status'] == 'completed'
    assert state['speech_status'] == 'running'
    assert state['final_status'] == 'pending'
    assert state['speech_pending_turn_ids'] == [turn]
    first_attempt = state['attempt_id']
    assert mock_openai_post.call_count == 1

    retry = api.put(f'/sessions/{sid}/learner-turns/{turn}/audio', content=learner_wav,
                    headers={'Content-Type': 'audio/wav'})
    assert retry.status_code == 200
    completed = api.post(url)
    assert completed.status_code == 201
    result = completed.json()
    assert result['status'] == 'completed'
    assert result['attempt_id'] != first_attempt
    assert result['transcript_status'] == result['final_status'] == 'completed'
    assert result['speech_status'] == 'completed'
    assert result['speech_pending_turn_ids'] == []
    assert mock_openai_post.call_count == 2


def test_final_synthesis_retry_reuses_transcript_result(
        ready_speech_evaluation, mock_openai_post, evaluation_response, synthesis_response):
    api, _, url = ready_speech_evaluation
    mock_openai_post.side_effect = [evaluation_response, httpx.ReadTimeout('private')]
    assert api.post(url).status_code == 504
    failed = api.get(url).json()
    assert failed['transcript_status'] == 'completed'
    assert failed['final_status'] == 'failed'
    assert failed['transcript_result'] is not None

    mock_openai_post.side_effect = [synthesis_response]
    completed = api.post(url)
    assert completed.status_code == 201
    assert completed.json()['status'] == 'completed'
    assert mock_openai_post.call_count == 3


@pytest.mark.parametrize('kind', ['timeout', 'failure', 'malformed'])
def test_speech_failure_returns_transcript_feedback(
        learner_turn, learner_wav, evaluation_response, synthesis_response, mock_speech_process,
        mock_openai_post, kind):
    if kind == 'timeout':
        mock_speech_process.side_effect = subprocess.TimeoutExpired(['worker'], 1)
    else:
        mock_speech_process.return_value = subprocess.CompletedProcess([], 1 if kind == 'failure' else 0,
                                                                       stdout=b'private provider error')
    api, _, url, upload = finish_speech_session(
        learner_turn, learner_wav, mock_openai_post, evaluation_response, synthesis_response)
    assert upload.status_code == 201
    response = api.post(url)
    assert response.status_code == 201
    assert 'private' not in response.text
    result = response.json()
    assert result['status'] == 'completed'
    assert result['speech_assessments'][0]['status'] == 'unavailable'
    assert result['speech_assessments'][0]['reason'] == 'provider_unavailable'
    assert result['not_assessed'] == ['pronunciation', 'spoken_fluency']
    assert mock_openai_post.call_count == 1


def test_identical_upload_retries_unavailable_assessment(
        learner_turn, learner_wav, mock_speech_process):
    api, settings, base, _ = learner_turn
    settings.azure_speech_key = SecretStr('speech-secret')
    settings.azure_speech_region = 'eastus'
    success = mock_speech_process.return_value
    mock_speech_process.side_effect = subprocess.TimeoutExpired(['worker'], 1)
    first = api.put(base + '/audio', content=learner_wav, headers={'Content-Type': 'audio/wav'})
    assert first.status_code == 201
    mock_speech_process.side_effect = None
    mock_speech_process.return_value = success
    second = api.put(base + '/audio', content=learner_wav, headers={'Content-Type': 'audio/wav'})
    assert second.status_code == 200
    with sqlite3.connect(settings.database_path) as db:
        cached = json.loads(db.execute('SELECT result FROM speech_assessments').fetchone()[0])
    assert cached['status'] == 'assessed'
    assert mock_speech_process.call_count == 2


@pytest.mark.parametrize('key,region', [('', 'eastus'), ('secret', ''), ('secret', 'https://evil.example')])
def test_speech_configuration(learner_turn, learner_wav, mock_speech_process,
                              mock_openai_post, evaluation_response, key, region):
    api, settings, base, transcript = learner_turn
    settings.azure_speech_key = SecretStr(key)
    settings.azure_speech_region = region
    assert api.put(base + '/audio', content=learner_wav,
                   headers={'Content-Type': 'audio/wav'}).status_code == 201
    with sqlite3.connect(settings.database_path) as db:
        cached = json.loads(db.execute('SELECT result FROM speech_assessments').fetchone()[0])
    assert cached['status'] == 'unavailable'
    assert cached['reason'] == 'not_configured'
    assert cached['duration_ms'] is None
    mock_speech_process.assert_not_called()


@pytest.mark.parametrize('bad', ['score', 'timing', 'empty', 'nan', 'shape'])
def test_invalid_speech_result_returns_transcript_feedback(
        learner_turn, learner_wav, evaluation_response, synthesis_response, mock_speech_process,
        mock_openai_post, speech_payload, bad):
    if bad == 'score':
        speech_payload[0]['NBest'][0]['PronunciationAssessment']['AccuracyScore'] = 101
    elif bad == 'nan':
        speech_payload[0]['NBest'][0]['PronunciationAssessment']['FluencyScore'] = float('nan')
    elif bad == 'timing':
        speech_payload[0]['NBest'][0]['Words'][0]['Offset'] = -1
    elif bad == 'empty':
        speech_payload[0]['NBest'] = []
    else:
        speech_payload = [None]
    mock_speech_process.return_value = subprocess.CompletedProcess([], 0,
        stdout=json.dumps({'segments': speech_payload}).encode())
    api, _, url, upload = finish_speech_session(
        learner_turn, learner_wav, mock_openai_post, evaluation_response, synthesis_response)
    assert upload.status_code == 201
    response = api.post(url)
    assert response.status_code == 201
    assert response.json()['speech_assessments'][0]['status'] == 'unavailable'
    assert response.json()['not_assessed'] == ['pronunciation', 'spoken_fluency']
    assert mock_openai_post.call_count == 1


def test_no_speech_is_insufficient(learner_turn, learner_wav, evaluation_response,
                                   synthesis_response, mock_openai_post, mock_speech_process):
    mock_speech_process.return_value = subprocess.CompletedProcess([], 0, stdout=b'{"segments":[]}')
    api, _, url, _ = finish_speech_session(
        learner_turn, learner_wav, mock_openai_post, evaluation_response, synthesis_response)
    result = api.post(url).json()
    assert result['speech_assessments'][0]['reason'] == 'no_recognized_speech'
    assert result['speech_assessments'][0]['segments'] == []
    assert result['not_assessed'] == ['pronunciation', 'spoken_fluency']


def test_few_words_insufficient(speech_payload):
    speech_payload[0]['NBest'][0]['Words'] = speech_payload[0]['NBest'][0]['Words'][:2]
    result = parse_assessment(speech_payload, {'turn_id': 'turn', 'sha256': 'hash'}, 4000)
    assert result.reason == 'too_few_words'
    assert result.segments == []


def test_short_audio(learner_turn, learner_wav, mock_openai_post, evaluation_response, mock_speech_process):
    import wave
    output = io.BytesIO()
    with wave.open(output, 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b'\0' * 32000)
    api, settings, base, transcript = learner_turn
    sid, turn = base.split('/')[2], base.split('/')[-1]
    settings.azure_speech_key = SecretStr('secret')
    settings.azure_speech_region = 'eastus'
    settings.azure_openai_evaluation_deployment = 'text'
    api.put(base + '/audio', content=output.getvalue(), headers={'Content-Type': 'audio/wav'})
    api.put(base + '/transcript', json=transcript)
    api.post(f'/sessions/{sid}/end')
    api.put(f'/sessions/{sid}/upload-manifest', json={
        'audio_turn_ids': [turn], 'transcript_turn_ids': [turn], 'agent_transcripts': []})
    mock_openai_post.return_value = evaluation_response
    response = api.post(f'/sessions/{sid}/evaluation')
    assert response.status_code == 201
    assert response.json()['speech_assessments'][0]['reason'] == 'too_short'
    mock_speech_process.assert_not_called()


def test_snapshot_rejects_changed_audio(ready_speech_evaluation, mock_speech_process):
    api, settings, url = ready_speech_evaluation
    sid = url.split('/')[2]
    _, record, _ = evaluation_record(settings.database_path, sid, '00000000-0000-4000-8000-000000000001', 'text')
    finish_evaluation(settings.database_path, record, error_code='test')
    with sqlite3.connect(settings.database_path) as db:
        db.execute('UPDATE learner_turns SET audio=? WHERE session_id=?', (b'changed', sid))
    mock_speech_process.reset_mock()
    assert api.post(url).status_code == 201
    mock_speech_process.assert_not_called()


def test_v1_retry_remains_transcript_only(ready_speech_evaluation, mock_speech_process):
    api, settings, url = ready_speech_evaluation
    sid = url.split('/')[2]
    _, record, snapshot = evaluation_record(settings.database_path, sid, '00000000-0000-4000-8000-000000000001', 'text')
    source = json.loads(snapshot)
    del source['audio_references']
    record = record.model_copy(update={'rubric_version': 'transcript-v1', 'status': 'failed'})
    with sqlite3.connect(settings.database_path) as db:
        db.execute('UPDATE session_evaluations SET snapshot=?, record=?',
                   (json.dumps(source), record.model_dump_json()))
    mock_speech_process.reset_mock()
    response = api.post(url)
    assert response.status_code == 201
    assert response.json()['speech_assessments'] == []
    mock_speech_process.assert_not_called()


def test_decode_wav_preserves_silence_and_duration(learner_wav):
    pcm = decode_audio(learner_wav, 'audio/wav', time.monotonic() + 10)
    assert len(pcm) == 128000


@pytest.mark.parametrize('audio,mime', [(b'not a wav', 'audio/wav'), (b'#EXTM3U\nhttps://example.com', 'audio/mpeg')])
def test_bad_audio(audio, mime):
    with pytest.raises(HTTPException) as error:
        decode_audio(audio, mime, time.monotonic() + 10)
    assert error.value.status_code == 422


def test_audio_limits(learner_wav, monkeypatch):
    monkeypatch.setattr('app.services.pronunciation.MAX_AUDIO_SECONDS', 1)
    with pytest.raises(HTTPException) as error:
        decode_audio(learner_wav, 'audio/wav', time.monotonic() + 10)
    assert error.value.status_code == 413
    with pytest.raises(HTTPException) as error:
        decode_audio(learner_wav, 'audio/wav', time.monotonic() - 1)
    assert error.value.status_code == 504


@pytest.mark.parametrize('container,codec,fmt,rate,mime', [
    ('webm', 'libopus', 'flt', 48000, 'audio/webm;codecs=opus'),
    ('ogg', 'libopus', 'flt', 48000, 'audio/ogg'),
    ('mp3', 'libmp3lame', 'fltp', 16000, 'audio/mpeg'),
    ('mp4', 'aac', 'fltp', 16000, 'audio/mp4'),
])
def test_compressed_audio(learner_wav, container, codec, fmt, rate, mime):
    output = io.BytesIO()
    with av.open(output, 'w', format=container) as encoded:
        stream = encoded.add_stream(codec, rate=rate)
        stream.layout = 'mono'
        resampler = av.AudioResampler(format=fmt, layout='mono', rate=rate)
        with av.open(io.BytesIO(learner_wav)) as source:
            for frame in source.decode(audio=0):
                for frame_out in resampler.resample(frame):
                    for packet in stream.encode(frame_out):
                        encoded.mux(packet)
        for frame_out in resampler.resample(None):
            for packet in stream.encode(frame_out):
                encoded.mux(packet)
        for packet in stream.encode(None):
            encoded.mux(packet)
    pcm = decode_audio(output.getvalue(), mime, time.monotonic() + 10)
    assert abs(len(pcm) / 32000 - 4) < 0.1


def test_partial_speech_progress_survives_provider_timeout(
        ready_speech_evaluation, learner_wav, mock_speech_process, mock_openai_post):
    api, settings, url = ready_speech_evaluation
    sid = url.split('/')[2]
    # Add a second audio-only turn before declaring a fresh two-audio inventory.
    # Adjust the manifest directly in this fixture: public manifests are immutable.
    turn = str(uuid4())
    mock_speech_process.reset_mock()
    mock_speech_process.side_effect = subprocess.TimeoutExpired(['worker'], 1)
    api.put(f'/sessions/{sid}/learner-turns/{turn}/audio', content=learner_wav,
            headers={'Content-Type': 'audio/wav'}).raise_for_status()
    with sqlite3.connect(settings.database_path) as db:
        manifest = json.loads(db.execute('SELECT upload_manifest FROM practice_sessions WHERE id=?',
                                        (sid,)).fetchone()[0])
        manifest['audio_turn_ids'].append(turn)
        db.execute('UPDATE practice_sessions SET upload_manifest=? WHERE id=?', (json.dumps(manifest), sid))
    response = api.post(url)
    assert response.status_code == 201
    assessments = response.json()['speech_assessments']
    assert sorted(item['status'] for item in assessments) == ['assessed', 'unavailable']
    assert mock_openai_post.call_count == 2
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute('SELECT count(*) FROM speech_assessments').fetchone()[0] == 2
    assert len(api.get(url).json()['speech_assessments']) == 2
    assert mock_speech_process.call_count == 1


def test_cache_storage_error(learner_turn, learner_wav, monkeypatch, mock_speech_process):
    api, settings, base, _ = learner_turn
    settings.azure_speech_key = SecretStr('speech-secret')
    settings.azure_speech_region = 'eastus'
    def fail(*args):
        raise sqlite3.OperationalError('secret database detail')
    monkeypatch.setattr('app.services.pronunciation.speech_cache', fail)
    response = api.put(base + '/audio', content=learner_wav, headers={'Content-Type': 'audio/wav'})
    assert response.status_code == 503
    assert 'secret' not in response.text
    mock_speech_process.assert_not_called()


def test_invalid_recording_fails_during_upload(learner_turn, mock_speech_process):
    api, settings, base, _ = learner_turn
    settings.azure_speech_key = SecretStr('speech-secret')
    settings.azure_speech_region = 'eastus'
    assert api.put(base + '/audio', content=b'not a wav',
                   headers={'Content-Type': 'audio/wav'}).status_code == 422
    mock_speech_process.assert_not_called()


def test_upload_timeout_budget(learner_turn, learner_wav, mock_speech_process, monkeypatch):
    api, settings, base, _ = learner_turn
    settings.azure_speech_key = SecretStr('speech-secret')
    settings.azure_speech_region = 'eastus'
    monkeypatch.setattr('app.services.pronunciation.SPEECH_BUDGET_SECONDS', -1)
    assert api.put(base + '/audio', content=learner_wav,
                   headers={'Content-Type': 'audio/wav'}).status_code == 504
    mock_speech_process.assert_not_called()


def test_provider_slot_saturation_is_bounded(
        learner_turn, learner_wav, mock_speech_process, monkeypatch):
    api, settings, base, _ = learner_turn
    settings.azure_speech_key = SecretStr('speech-secret')
    settings.azure_speech_region = 'eastus'
    slot = type('NoSlot', (), {'acquire': lambda self, timeout: False,
                               'release': lambda self: None})()
    monkeypatch.setattr('app.services.pronunciation.SPEECH_PROVIDER_SLOTS', slot)
    response = api.put(base + '/audio', content=learner_wav,
                       headers={'Content-Type': 'audio/wav'})
    assert response.status_code == 201
    with sqlite3.connect(settings.database_path) as db:
        cached = json.loads(db.execute('SELECT result FROM speech_assessments').fetchone()[0])
    assert cached['status'] == 'unavailable'
    assert cached['reason'] == 'provider_unavailable'
    mock_speech_process.assert_not_called()


def test_optional_prosody(speech_payload):
    del speech_payload[0]['NBest'][0]['PronunciationAssessment']['ProsodyScore']
    result = parse_assessment(speech_payload, {'turn_id': 'turn', 'sha256': 'hash'}, 4000)
    assert result.segments[0].prosody_score is None


def test_rest_protocol_and_flat_scores(settings, learner_wav, speech_payload, monkeypatch):
    settings.azure_speech_key = SecretStr('speech-secret')
    settings.azure_speech_region = 'eastus'
    payload = speech_payload[0]
    hypothesis = payload['NBest'][0]
    hypothesis.update(hypothesis.pop('PronunciationAssessment'))
    for word in hypothesis['Words']:
        word.update(word.pop('PronunciationAssessment'))
        for phoneme in word['Phonemes']:
            phoneme.update(phoneme.pop('PronunciationAssessment'))
    calls = []

    def post(url, **kwargs):
        calls.append((url, kwargs))
        return httpx.Response(200, request=httpx.Request('POST', url), json=payload)

    monkeypatch.setattr('app.services.pronunciation.httpx.post', post)
    pcm = decode_audio(learner_wav, 'audio/wav', time.monotonic() + 10)
    raw = recognize_audio_rest(pcm, settings, 10)
    result = parse_assessment(raw, {'turn_id': 'turn', 'sha256': 'hash'}, 4000)

    assert result.status == 'assessed'
    assert result.segments[0].accuracy_score == 85
    assert len(calls) == 1
    url, request = calls[0]
    assert url == 'https://eastus.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1'
    assert request['params']['format'] == 'detailed'
    assert request['headers']['Ocp-Apim-Subscription-Key'] == 'speech-secret'
    header = json.loads(base64.b64decode(
        request['headers']['Pronunciation-Assessment']).decode())
    assert header['ReferenceText'] == ''
    assert header['Granularity'] == 'Phoneme'
    assert request['content'][:4] == b'RIFF'


def test_ios_header_only_wav_is_rejected_without_speech_samples():
    """Regression for the actual 4096-byte recordings seen on October 10."""
    import struct
    chunks = (
        b'JUNK' + struct.pack('<I', 28) + bytes(28)
        + b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16)
        + b'FLLR' + struct.pack('<I', 4008) + bytes(4008)
        + b'data' + struct.pack('<I', 0)
    )
    audio = b'RIFF' + struct.pack('<I', 4 + len(chunks)) + b'WAVE' + chunks
    assert len(audio) == 4096
    with pytest.raises(HTTPException) as caught:
        decode_audio(audio, 'audio/wav', time.monotonic() + 10)
    assert caught.value.status_code == 422
    assert caught.value.detail == 'Learner recording contains no audio samples.'

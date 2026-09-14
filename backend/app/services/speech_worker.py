"""Bounded-lifetime SDK process. PCM enters stdin; only structured results leave stdout."""
import json
import os
import sys
from threading import Event, Lock


def recognize_pcm(pcm, key, region, sdk=None):
    if sdk is None:
        import azure.cognitiveservices.speech as sdk
    config = sdk.SpeechConfig(subscription=key, region=region)
    config.output_format = sdk.OutputFormat.Detailed
    stream = sdk.audio.PushAudioInputStream(stream_format=sdk.audio.AudioStreamFormat(
        samples_per_second=16000, bits_per_sample=16, channels=1))
    recognizer = sdk.SpeechRecognizer(speech_config=config, language='en-US',
                                     audio_config=sdk.audio.AudioConfig(stream=stream))
    assessment = sdk.PronunciationAssessmentConfig(
        reference_text='', grading_system=sdk.PronunciationAssessmentGradingSystem.HundredMark,
        granularity=sdk.PronunciationAssessmentGranularity.Phoneme, enable_miscue=False)
    assessment.enable_prosody_assessment()
    assessment.apply_to(recognizer)
    done, lock = Event(), Lock()
    segments, errors = [], []

    def recognized(event):
        with lock:
            try:
                if event.result.reason == sdk.ResultReason.RecognizedSpeech:
                    segments.append(json.loads(event.result.properties.get_property(
                        sdk.PropertyId.SpeechServiceResponse_JsonResult)))
                elif event.result.reason != sdk.ResultReason.NoMatch:
                    errors.append('provider_failure')
            except (ValueError, TypeError, KeyError):
                errors.append('provider_failure')

    def canceled(event):
        with lock:
            # EndOfStream cancellation is normal after a finite push stream.
            if event.reason != sdk.CancellationReason.EndOfStream:
                errors.append('provider_failure')
        done.set()

    recognizer.recognized.connect(recognized)
    recognizer.canceled.connect(canceled)
    recognizer.session_stopped.connect(lambda event: done.set())
    try:
        recognizer.start_continuous_recognition_async().get()
        stream.write(pcm)
        stream.close()
        done.wait()  # Parent enforces a hard timeout even if native SDK blocks.
    finally:
        recognizer.stop_continuous_recognition_async().get()
        stream.close()
    with lock:
        if errors:
            raise ValueError('Speech provider failed')
        return segments


if __name__ == '__main__':
    try:
        result = recognize_pcm(sys.stdin.buffer.read(), os.environ['AZURE_SPEECH_KEY'],
                               os.environ['AZURE_SPEECH_REGION'])
        sys.stdout.write(json.dumps({'segments': result}, allow_nan=False))
    except Exception:
        # Never expose native SDK diagnostics, recognized content or credentials on failure.
        sys.stdout.write('{"error":"provider_failure"}')
        sys.exit(1)

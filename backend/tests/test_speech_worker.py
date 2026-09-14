import pytest
from types import SimpleNamespace
from app.services.speech_worker import recognize_pcm


def test_sdk_configuration_and_continuous_recognition(fake_speech_sdk, speech_payload):
    sdk, recognizer, stream, _, event = fake_speech_sdk
    assert recognize_pcm(b'pcm', 'secret', 'eastus', sdk) == speech_payload
    sdk.SpeechConfig.assert_called_once_with(subscription='secret', region='eastus')
    sdk.audio.AudioStreamFormat.assert_called_once_with(samples_per_second=16000, bits_per_sample=16, channels=1)
    sdk.PronunciationAssessmentConfig.assert_called_once_with(
        reference_text='', grading_system=sdk.PronunciationAssessmentGradingSystem.HundredMark,
        granularity=sdk.PronunciationAssessmentGranularity.Phoneme, enable_miscue=False)
    config = sdk.PronunciationAssessmentConfig.return_value
    config.enable_prosody_assessment.assert_called_once()
    config.apply_to.assert_called_once_with(recognizer)
    assert sdk.SpeechRecognizer.call_args.kwargs['language'] == 'en-US'
    recognizer.start_continuous_recognition_async.assert_called_once()
    recognizer.stop_continuous_recognition_async.assert_called_once()
    stream.write.assert_called_once_with(b'pcm')
    assert stream.close.called
    event.result.properties.get_property.assert_called_once_with(sdk.PropertyId.SpeechServiceResponse_JsonResult)


@pytest.mark.parametrize('kind', ['provider_error', 'malformed', 'no_match', 'end_of_stream'])
def test_sdk_completion_and_cancellation(fake_speech_sdk, kind):
    sdk, recognizer, stream, callbacks, event = fake_speech_sdk
    if kind == 'malformed':
        event.result.properties.get_property.return_value = '{bad'
    elif kind == 'no_match':
        event.result.reason = sdk.ResultReason.NoMatch
    else:
        reason = sdk.CancellationReason.Error if kind == 'provider_error' else sdk.CancellationReason.EndOfStream
        stream.write.side_effect = lambda pcm: callbacks['canceled'](SimpleNamespace(reason=reason))
    if kind in ('provider_error', 'malformed'):
        with pytest.raises(ValueError):
            recognize_pcm(b'pcm', 'secret', 'eastus', sdk)
    else:
        assert recognize_pcm(b'pcm', 'secret', 'eastus', sdk) == []
    recognizer.stop_continuous_recognition_async.assert_called_once()
    assert stream.close.called

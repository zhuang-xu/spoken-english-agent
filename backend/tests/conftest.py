"""Shared pytest fixtures, available to every test file without imports."""
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import Settings, get_settings
from app.main import app
from app.services import realtime


@pytest.fixture
def settings(tmp_path):
    """Use a fake API key and a fresh database for each test."""
    return Settings(
        _env_file=None,
        database_path=str(tmp_path / "test.sqlite3"),
        azure_openai_api_key="server-secret",
        azure_openai_endpoint="https://test-resource.openai.azure.com",
        azure_openai_deployment="test-realtime-deployment",
    )


@pytest.fixture
def realtime_response():
    """Default successful OpenAI Realtime client-secret response."""
    return httpx.Response(
        200,
        request=httpx.Request("POST", "https://test-resource.openai.azure.com/openai/v1/realtime/client_secrets"),
        json={
            "value": "ephemeral-token",
            "expires_at": int((datetime.now(timezone.utc) + timedelta(minutes=1)).timestamp()),
            "session": {"id": "provider-1"},
        },
    )


@pytest.fixture
def mock_openai_post(monkeypatch, realtime_response):
    """Replace the synchronous provider POST and record calls.

    Set return_value to another httpx.Response, or side_effect to an exception
    or callback. The default response is specific to Realtime client secrets.
    Each test gets a fresh mock; monkeypatch restores HTTP afterward.
    """
    mock = Mock(return_value=realtime_response)
    monkeypatch.setattr(realtime.httpx, "post", mock)
    return mock


@pytest.fixture
def client(settings, mock_openai_post, monkeypatch):
    """API client with isolated settings and mocked provider HTTP."""
    monkeypatch.setitem(app.dependency_overrides, get_settings, lambda: settings)
    with TestClient(app) as test_client:
        yield test_client, settings


@pytest.fixture
def learner_turn(client):
    """An active session and reusable learner turn upload URLs and transcript."""
    from uuid import uuid4

    api, settings = client
    session_id = api.post("/sessions", json={
        "speaking_goal": "Interview practice", "level": "B1",
        "preferred_topic": "work", "session_duration_minutes": 15,
    }).json()["session"]["id"]
    turn_id = str(uuid4())
    return api, settings, f"/sessions/{session_id}/learner-turns/{turn_id}", {
        "text": "I built an application.", "start_ms": 1000, "end_ms": 3500,
        "provider_item_id": "item_learner_1",
    }


@pytest.fixture
def agent_transcript(learner_turn):
    """An agent content part in an active session, with observed playback timing."""
    api, settings, base, _ = learner_turn
    session_id = base.split('/')[2]
    return api, settings, f"/sessions/{session_id}/agent-items", {
        "text": "What did you build?", "response_id": "resp_1",
        "previous_item_id": "learner_1", "playback_status": "completed",
        "start_ms": 4000, "end_ms": 5500,
    }


@pytest.fixture
def evaluation_payload():
    return {
        'summary': 'A clear short response.',
        'grammar': {'score': 4, 'feedback': 'Correct past tense.'},
        'vocabulary': {'score': 3, 'feedback': 'Add specific technical details.'},
        'coherence': {'score': None, 'feedback': 'Too little text to assess progression.'},
        'strengths': ['Clear meaning.'], 'next_steps': ['Explain one implementation decision.'],
        'corrections': [],
    }


@pytest.fixture
def evaluation_response(evaluation_payload):
    import json
    return httpx.Response(200, request=httpx.Request('POST', 'https://test-resource.openai.azure.com'),
                          json={'choices': [{'finish_reason': 'stop', 'message': {
                              'content': json.dumps(evaluation_payload), 'refusal': None}}]})


@pytest.fixture
def synthesis_response(evaluation_payload):
    import json
    payload = {key: evaluation_payload[key] for key in ('summary', 'strengths', 'next_steps')}
    return httpx.Response(200, request=httpx.Request('POST', 'https://test-resource.openai.azure.com'),
                          json={'choices': [{'finish_reason': 'stop', 'message': {
                              'content': json.dumps(payload), 'refusal': None}}]})


@pytest.fixture
def ready_evaluation(learner_turn, mock_openai_post, evaluation_response):
    api, settings, base, transcript = learner_turn
    session = base.split('/')[2]
    turn = base.split('/')[-1]
    api.put(base + '/transcript', json=transcript).raise_for_status()
    api.post(f'/sessions/{session}/end').raise_for_status()
    api.put(f'/sessions/{session}/upload-manifest', json={
        'audio_turn_ids': [], 'transcript_turn_ids': [turn], 'agent_transcripts': [],
    }).raise_for_status()
    settings.azure_openai_evaluation_deployment = 'test-evaluation'
    mock_openai_post.reset_mock()
    mock_openai_post.return_value = evaluation_response
    return api, settings, f'/sessions/{session}/evaluation'


@pytest.fixture
def learner_wav():
    """A decodable 4-second test waveform, not real learner speech."""
    import io
    import math
    import struct
    import wave
    output = io.BytesIO()
    with wave.open(output, 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b''.join(struct.pack('<h', int(1000 * math.sin(i * 0.08)))
                                 for i in range(64000)))
    return output.getvalue()


@pytest.fixture
def speech_payload():
    words = []
    for i, text in enumerate(['I', 'built', 'a', 'useful', 'application']):
        words.append({'Word': text, 'Offset': i * 6_000_000, 'Duration': 5_000_000,
                      'PronunciationAssessment': {'AccuracyScore': 85, 'ErrorType': 'None'},
                      'Phonemes': [{'Phoneme': 'a', 'PronunciationAssessment': {'AccuracyScore': 85}}]})
    return [{'RecognitionStatus': 'Success', 'Offset': 0, 'Duration': 30_000_000,
             'NBest': [{'Display': 'I built a useful application.', 'Words': words,
                       'PronunciationAssessment': {'AccuracyScore': 85, 'FluencyScore': 80,
                                                  'ProsodyScore': 75}}]}]


@pytest.fixture
def mock_speech_process(monkeypatch, speech_payload):
    """Mock only the SDK process boundary; keep decoding, parsing and persistence real."""
    import json
    import subprocess
    mock = Mock(return_value=subprocess.CompletedProcess(
        args=[], returncode=0, stdout=json.dumps({'segments': speech_payload}).encode()))
    monkeypatch.setattr('app.services.pronunciation.subprocess.run', mock)
    return mock


@pytest.fixture
def ready_speech_evaluation(learner_turn, learner_wav, mock_openai_post,
                            evaluation_response, synthesis_response, mock_speech_process):
    api, settings, base, transcript = learner_turn
    sid, turn = base.split('/')[2], base.split('/')[-1]
    from pydantic import SecretStr
    settings.azure_speech_key = SecretStr('speech-secret')
    settings.azure_speech_region = 'eastus'
    api.put(base + '/transcript', json=transcript).raise_for_status()
    api.put(base + '/audio', content=learner_wav, headers={'Content-Type': 'audio/wav'}).raise_for_status()
    api.post(f'/sessions/{sid}/end').raise_for_status()
    api.put(f'/sessions/{sid}/upload-manifest', json={
        'audio_turn_ids': [turn], 'transcript_turn_ids': [turn], 'agent_transcripts': []}).raise_for_status()
    settings.azure_openai_evaluation_deployment = 'test-evaluation'
    mock_openai_post.reset_mock()
    mock_openai_post.side_effect = [evaluation_response, synthesis_response]
    return api, settings, f'/sessions/{sid}/evaluation'


@pytest.fixture
def fake_speech_sdk(speech_payload):
    """SDK event boundary with real SDK enums/specs; no network or credentials needed."""
    import json
    from types import SimpleNamespace
    import azure.cognitiveservices.speech as real_sdk
    callbacks = {}
    def signal(name):
        return SimpleNamespace(connect=Mock(side_effect=lambda fn: callbacks.__setitem__(name, fn)))
    recognizer = SimpleNamespace(
        recognized=signal('recognized'), canceled=signal('canceled'), session_stopped=signal('stopped'),
        start_continuous_recognition_async=Mock(), stop_continuous_recognition_async=Mock())
    properties = Mock(spec=real_sdk.PropertyCollection)
    properties.get_property.return_value = json.dumps(speech_payload[0])
    event = SimpleNamespace(result=SimpleNamespace(reason=real_sdk.ResultReason.RecognizedSpeech,
                                                  properties=properties))
    def finish(pcm):
        callbacks['recognized'](event)
        callbacks['stopped'](None)
    stream = SimpleNamespace(write=Mock(side_effect=finish), close=Mock())
    sdk = SimpleNamespace(
        SpeechConfig=Mock(spec=real_sdk.SpeechConfig),
        OutputFormat=real_sdk.OutputFormat,
        ResultReason=real_sdk.ResultReason, PropertyId=real_sdk.PropertyId,
        CancellationReason=real_sdk.CancellationReason,
        SpeechRecognizer=Mock(spec=real_sdk.SpeechRecognizer, return_value=recognizer),
        PronunciationAssessmentConfig=Mock(spec=real_sdk.PronunciationAssessmentConfig),
        PronunciationAssessmentGradingSystem=real_sdk.PronunciationAssessmentGradingSystem,
        PronunciationAssessmentGranularity=real_sdk.PronunciationAssessmentGranularity,
        audio=SimpleNamespace(AudioStreamFormat=Mock(spec=real_sdk.audio.AudioStreamFormat),
                              PushAudioInputStream=Mock(return_value=stream),
                              AudioConfig=Mock(spec=real_sdk.audio.AudioConfig)))
    return sdk, recognizer, stream, callbacks, event

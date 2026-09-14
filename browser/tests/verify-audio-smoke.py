"""Check a browser-generated WebM against the real upload/storage/decoder flow.

Run after audio-smoke.cjs. Only the external credential provider is mocked.
"""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
import tempfile
import time
from unittest.mock import patch
from uuid import uuid4

import httpx
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'backend'))
from app.config import Settings, get_settings
from app.main import app
from app.services.pronunciation import decode_audio


def main():
    audio = Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/spoken-browser-recording.webm').read_bytes()
    mime = 'audio/webm;codecs=opus'
    pcm = decode_audio(audio, mime, time.monotonic() + 10)
    assert len(pcm) > 32000, 'Expected at least one second of decodable PCM'
    with tempfile.TemporaryDirectory() as directory:
        settings = Settings(_env_file=None, database_path=str(Path(directory) / 'audio.sqlite3'),
                            azure_openai_api_key='synthetic-key', azure_openai_deployment='synthetic-deployment',
                            azure_openai_endpoint='https://test-resource.openai.azure.com')
        app.dependency_overrides[get_settings] = lambda: settings
        response = httpx.Response(200, request=httpx.Request('POST', 'https://test.invalid'), json={
            'value': 'synthetic-token', 'expires_at': int((datetime.now(timezone.utc) + timedelta(minutes=1)).timestamp()),
            'session': {'id': 'synthetic-provider'},
        })
        try:
            with patch('app.services.realtime.httpx.post', return_value=response), TestClient(app) as api:
                started = api.post('/sessions', json={'speaking_goal': 'Practice speaking', 'level': 'B1',
                    'preferred_topic': 'Work', 'session_duration_minutes': 5})
                assert started.status_code == 201
                session_id = started.json()['session']['id']
                turn_id = str(uuid4())
                base = f'/sessions/{session_id}/learner-turns/{turn_id}'
                assert api.put(base + '/audio', content=audio, headers={'Content-Type': mime}).status_code == 201
                assert api.put(base + '/audio', content=audio, headers={'Content-Type': mime}).status_code == 200
                assert api.put(base + '/transcript', json={'text': 'Synthetic browser test audio.',
                    'start_ms': 0, 'end_ms': len(pcm) // 32, 'provider_item_id': 'synthetic-item'}).status_code == 201
                assert api.post(f'/sessions/{session_id}/end').status_code == 200
                status = api.put(f'/sessions/{session_id}/upload-manifest', json={
                    'audio_turn_ids': [turn_id], 'transcript_turn_ids': [turn_id], 'agent_transcripts': [],
                })
                assert status.status_code == 200
                assert status.json()['ready_for_evaluation'] is True
        finally:
            app.dependency_overrides.pop(get_settings, None)
    print(f'Browser recording verified: {len(audio)} bytes, {len(pcm) / 32:.0f} ms decoded PCM; upload/retry/manifest passed.')


if __name__ == '__main__':
    main()

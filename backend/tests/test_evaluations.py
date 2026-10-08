import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import httpx
import pytest

from app.storage.evaluations import evaluation_record, finish_evaluation


def test_create_read_replay(ready_evaluation, mock_openai_post):
    api, settings, url = ready_evaluation
    assert api.get(url).status_code == 404
    created = api.post(url)
    assert created.status_code == 201
    assert created.headers['cache-control'] == 'no-store'
    body = created.json()
    assert body['status'] == 'completed'
    assert body['transcript_status'] == body['final_status'] == 'completed'
    assert body['speech_status'] == 'not_assessed'
    assert body['transcript_result'] == body['result']
    assert body['not_assessed'] == ['pronunciation', 'spoken_fluency']
    assert body['result']['coherence']['score'] is None
    assert api.get(url).json() == body
    settings.azure_openai_api_key = ''
    # A saved result needs neither provider configuration nor another HTTP call.
    settings.azure_openai_evaluation_deployment = ''
    assert api.post(url).json() == body
    assert mock_openai_post.call_count == 1
    with sqlite3.connect(settings.database_path) as db:
        snapshot, record = db.execute('SELECT snapshot, record FROM session_evaluations').fetchone()
    assert 'server-secret' not in snapshot + record
    assert 'ephemeral-token' not in snapshot + record


@pytest.mark.parametrize('kind,status', [('timeout', 504), ('rejection', 502), ('malformed', 502),
                                        ('empty', 502), ('refused', 502), ('truncated', 502)])
def test_provider_failure_and_retry(ready_evaluation, mock_openai_post, evaluation_response, kind, status):
    api, _, url = ready_evaluation
    if kind == 'timeout':
        mock_openai_post.side_effect = httpx.ReadTimeout('secret provider detail')
    else:
        bodies = {'malformed': {'choices': [{'finish_reason': 'stop', 'message': {'content': '{}'}}]},
                  'empty': {'choices': []},
                  'refused': {'choices': [{'finish_reason': 'stop', 'message': {'refusal': 'no'}}]},
                  'truncated': {'choices': [{'finish_reason': 'length', 'message': {}}]},
                  'rejection': {'error': 'secret provider detail'}}
        mock_openai_post.return_value = httpx.Response(400 if kind == 'rejection' else 200,
            request=httpx.Request('POST', 'https://test.example'), json=bodies[kind])
    response = api.post(url)
    assert response.status_code == status
    assert 'secret' not in response.text
    failed = api.get(url).json()
    assert failed['status'] == 'failed'
    mock_openai_post.side_effect = None
    mock_openai_post.return_value = evaluation_response
    assert api.post(url).status_code == 201
    completed = api.get(url).json()
    assert completed['input_sha256'] == failed['input_sha256']
    assert completed['attempt_id'] != failed['attempt_id']


@pytest.mark.parametrize('change', ['bad_score', 'bad_quote', 'bad_turn', 'blank_step', 'extra'])
def test_invalid_result(ready_evaluation, mock_openai_post, evaluation_payload, change):
    api, _, url = ready_evaluation
    if change == 'bad_score':
        evaluation_payload['grammar']['score'] = 6
    elif change == 'blank_step':
        evaluation_payload['next_steps'] = [' ']
    elif change == 'extra':
        evaluation_payload['pronunciation'] = 5
    else:
        snapshot = json.loads(evaluation_record(ready_evaluation[1].database_path,
            url.split('/')[2], '00000000-0000-4000-8000-000000000001', 'test-evaluation')[2])
        turn = snapshot['learner_transcripts'][0]['turn_id']
        evaluation_payload['corrections'] = [{'turn_id': turn if change == 'bad_quote' else 'unknown',
            'original': 'invented' if change == 'bad_quote' else 'I built an application.',
            'improved': 'A better sentence.', 'explanation': 'Why.'}]
        # Mark the reservation failed so the route can retry it.
        record = evaluation_record(ready_evaluation[1].database_path, url.split('/')[2], '00000000-0000-4000-8000-000000000001')[1]
        finish_evaluation(ready_evaluation[1].database_path, record, error_code='provider_failure')
    mock_openai_post.return_value = httpx.Response(200, request=httpx.Request('POST', 'https://test.example'),
        json={'choices': [{'finish_reason': 'stop', 'message': {'content': json.dumps(evaluation_payload)}}]})
    assert api.post(url).status_code == 502
    assert api.get(url).json()['status'] == 'failed'


def test_not_ready_and_validation(learner_turn, mock_openai_post):
    api, settings, base, _ = learner_turn
    settings.azure_openai_evaluation_deployment = 'text'
    url = f'/sessions/{base.split("/")[2]}/evaluation'
    mock_openai_post.reset_mock()
    assert api.post(url).status_code == 409
    assert api.post('/sessions/not-uuid/evaluation').status_code == 422
    assert api.post(f'/sessions/{uuid4()}/evaluation').status_code == 404
    assert api.get(f'/sessions/{uuid4()}/evaluation').status_code == 404
    mock_openai_post.assert_not_called()


@pytest.mark.parametrize('setting,value', [('azure_openai_evaluation_deployment', ''),
    ('azure_openai_endpoint', 'http://test.example'), ('azure_openai_endpoint', 'https://user:pass@test.example')])
def test_configuration(ready_evaluation, mock_openai_post, setting, value):
    api, settings, url = ready_evaluation
    setattr(settings, setting, value)
    assert api.post(url).status_code == 503
    mock_openai_post.assert_not_called()


def test_storage_failure(ready_evaluation, monkeypatch):
    api, _, url = ready_evaluation
    def fail(*args):
        raise sqlite3.OperationalError('secret storage detail')
    monkeypatch.setattr('app.services.evaluations.evaluation_record', fail)
    assert api.get(url).status_code == 503
    assert api.post(url).status_code == 503


def test_finish_storage_failure(ready_evaluation, monkeypatch):
    api, _, url = ready_evaluation
    def fail(*args):
        raise sqlite3.OperationalError('secret')
    monkeypatch.setattr('app.services.evaluations.finish_evaluation', fail)
    assert api.post(url).status_code == 503
    assert api.get(url).json()['status'] == 'running'


def test_concurrent_reservation_and_stale_fencing(ready_evaluation):
    api, settings, url = ready_evaluation
    sid = url.split('/')[2]
    def reserve(_):
        return evaluation_record(settings.database_path, sid, '00000000-0000-4000-8000-000000000001', 'test-evaluation')
    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(reserve, range(2)))
    assert sorted(x[0] for x in outcomes) == ['reserved', 'running']
    old = outcomes[0][1]
    assert api.get(url).json()['status'] == 'running'
    running = api.post(url)
    assert running.status_code == 409
    assert running.headers['retry-after'] == '5'
    stale = old.model_copy(update={'started_at': datetime.now(timezone.utc) - timedelta(minutes=6)})
    with sqlite3.connect(settings.database_path) as db:
        db.execute('UPDATE session_evaluations SET record=?', (stale.model_dump_json(),))
    fresh = reserve(None)[1]
    assert fresh.attempt_id != old.attempt_id
    assert finish_evaluation(settings.database_path, old, error_code='provider_failure') is None
    assert api.get(url).json()['attempt_id'] == fresh.attempt_id


def test_late_upload_preserves_snapshot(ready_evaluation, mock_openai_post, evaluation_response):
    api, settings, url = ready_evaluation
    sid = url.split('/')[2]
    _, record, snapshot = evaluation_record(settings.database_path, sid, '00000000-0000-4000-8000-000000000001', 'original-deployment')
    finish_evaluation(settings.database_path, record, error_code='provider_failure')
    api.put(f'/sessions/{sid}/learner-turns/{uuid4()}/transcript', json={
        'text': 'Late undeclared text', 'start_ms': 5000, 'end_ms': 6000}).raise_for_status()
    assert not api.get(f'/sessions/{sid}/data-status').json()['ready_for_evaluation']
    assert api.post(url).status_code == 201
    request = mock_openai_post.call_args.kwargs['json']
    assert request['model'] == 'original-deployment'
    assert request['messages'][1]['content'] == snapshot


def test_oversized_snapshot(ready_evaluation, monkeypatch, mock_openai_post):
    api, _, url = ready_evaluation
    monkeypatch.setattr('app.storage.evaluations.MAX_SNAPSHOT_BYTES', 1)
    assert api.post(url).status_code == 413
    assert api.get(url).status_code == 404
    mock_openai_post.assert_not_called()


@pytest.mark.parametrize('body', [[], {'choices': {}}, {'choices': [None]},
                                  {'choices': [{'message': []}]}])
def test_malformed_envelope(ready_evaluation, mock_openai_post, body):
    api, _, url = ready_evaluation
    mock_openai_post.return_value = httpx.Response(200,
        request=httpx.Request('POST', 'https://test.example'), json=body)
    assert api.post(url).status_code == 502


def test_missing_key(ready_evaluation, mock_openai_post):
    from pydantic import SecretStr
    api, settings, url = ready_evaluation
    settings.azure_openai_api_key = SecretStr('')
    assert api.post(url).status_code == 503
    mock_openai_post.assert_not_called()


@pytest.mark.parametrize('mode', ['missing_manifest', 'missing_upload', 'empty'])
def test_ended_but_not_evaluable(learner_turn, mock_openai_post, mode):
    api, settings, base, _ = learner_turn
    settings.azure_openai_evaluation_deployment = 'text'
    sid, turn = base.split('/')[2], base.split('/')[-1]
    api.post(f'/sessions/{sid}/end').raise_for_status()
    if mode != 'missing_manifest':
        api.put(f'/sessions/{sid}/upload-manifest', json={'audio_turn_ids': [],
            'transcript_turn_ids': [turn] if mode == 'missing_upload' else [],
            'agent_transcripts': []}).raise_for_status()
    mock_openai_post.reset_mock()
    assert api.post(f'/sessions/{sid}/evaluation').status_code == 409
    mock_openai_post.assert_not_called()

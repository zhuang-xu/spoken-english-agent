import json
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from unittest.mock import Mock
from uuid import uuid4

import httpx
import pytest

from app.schemas import BatchFindings, EvidenceSelection, SessionAggregation
from app.services import evaluation_batches as batches
from app.services.evaluation_budget import ContextLimit, encoded, fits
from app.services.evaluation_provider import provider_schema

ACCOUNT = '00000000-0000-4000-8000-000000000001'


def source(count=3, length=5000):
    return {'preferences': {'level': 'B1', 'speaking_goal': 'Interview practice'},
            'learner_transcripts': [{'turn_id': str(uuid4()), 'text': 'A' * length,
                'start_ms': i * 1000, 'end_ms': i * 1000 + 900} for i in range(count)],
            'agent_transcripts': []}


def findings(payload, rich=False):
    observations = []
    for i, category in enumerate(['grammar', 'vocabulary', 'coherence'] * (2 if rich else 1)):
        part = payload['sources'][0]
        observations.append({'source_id': part['source_id'], 'start_char': i, 'end_char': i + 1,
            'quote': part['text'][i:i+1], 'category': category, 'polarity': 'strength',
            'finding': ('Supported language. ' * 15)[:280] if rich else 'Supported language.'})
    return BatchFindings(observations=observations, corrections=[])


def fake_provider(payload, instructions, name, model, deployment, settings):
    data = json.loads(payload)
    if model is BatchFindings:
        return findings(data, rich=True)
    ids = [i['id'] for i in data['observations']]
    if model is EvidenceSelection:
        # Preserve different categories and representative positions.
        return EvidenceSelection(observation_ids=(ids[:3] + ids[-3:]) if len(ids) > 6 else ids,
                                 correction_ids=[])
    assert model is SessionAggregation
    return SessionAggregation(summary='Representative evidence across the session.',
        grammar={'score': 4, 'feedback': 'Supported grammar.'},
        vocabulary={'score': 4, 'feedback': 'Supported vocabulary.'},
        coherence={'score': 4, 'feedback': 'Supported coherence.'},
        strengths=['Clear language.'], next_steps=['Add one concrete example.'],
        observation_ids=ids[:6], correction_ids=[])


def configured(settings):
    settings.azure_openai_evaluation_deployment = 'test-text'
    return settings


def finish(settings, sid, data, limit=200):
    pending = []
    for _ in range(limit):
        try:
            return batches.advance(settings, sid, data, final=True), pending
        except batches.BatchPending as progress:
            pending.append((progress.total, progress.completed))
    pytest.fail('Evaluation never completed')


def test_partition_unicode_coverage_and_context(settings):
    settings = configured(settings)
    data = source(2, 20_000)
    data['learner_transcripts'][0]['text'] = '你好。' * 6000
    data['agent_transcripts'] = [{'item_id': 'agent', 'content_index': 0,
        'text': 'Can you explain?', 'start_ms': 0, 'end_ms': 500, 'playback_status': 'interrupted'},
        {'item_id': 'untimed', 'content_index': 0, 'text': 'Unknown.',
         'start_ms': None, 'end_ms': None, 'playback_status': 'unknown'}]
    config = batches.configuration(settings)
    plan = batches.windows(data, config)
    for turn in data['learner_transcripts']:
        parts = [s for p in plan for s in p['sources'] if s['turn_id'] == turn['turn_id']]
        assert ''.join(p['text'] for p in parts) == turn['text']
        assert [p['offset'] for p in parts] == [sum(len(v['text']) for v in parts[:i]) for i in range(len(parts))]
    for payload in plan:
        assert fits(encoded(payload), batches.BATCH_INSTRUCTIONS, provider_schema(BatchFindings), config['capacity'])
        assert payload['agent_context'][0]['playback_status'] == 'interrupted'
        assert payload['agent_context'][1]['start_ms'] is None


def test_quote_and_span_validation():
    payload = {'sources': [{'source_id': 's', 'text': 'I go yesterday.'}]}
    result = BatchFindings(observations=[], corrections=[{
        'source_id': 's', 'start_char': 2, 'end_char': 4, 'original': 'go',
        'improved': 'went', 'explanation': 'Past tense.'}])
    batches.validate_findings(result, payload)
    for change in ({'source_id': 'invented'}, {'original': 'invented'}):
        invalid = result.model_copy(update={'corrections': [result.corrections[0].model_copy(update=change)]})
        with pytest.raises(ValueError, match='Invalid source'):
            batches.validate_findings(invalid, payload)


def test_checkpoint_reuse_and_hierarchical_reduction(settings, monkeypatch):
    settings = configured(settings)
    mock = Mock(side_effect=fake_provider)
    monkeypatch.setattr(batches, '_provider_result', mock)
    data = source(35, 12_000)
    result, pending = finish(settings, 'session', data)
    assert result.grammar.score == 4
    assert pending and pending[-1][0] == pending[-1][1]
    kinds = [call.args[2] for call in mock.call_args_list]
    assert 'evidence_selection' in kinds
    assert kinds.count('session_aggregation') == 1
    before = mock.call_count
    again, more = finish(settings, 'session', data)
    assert again == result and not more
    assert mock.call_count == before
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute('SELECT calls FROM evaluation_batch_plans').fetchone()[0] == before


def test_early_trigger_then_final_reuses_findings(learner_turn, monkeypatch):
    api, settings, base, transcript = learner_turn
    configured(settings)
    monkeypatch.setattr(batches, 'TRIGGER_BYTES', 100)
    provider = Mock(side_effect=fake_provider)
    monkeypatch.setattr(batches, '_provider_result', provider)
    assert api.put(base + '/transcript', json=transcript).status_code == 201
    sid, tid = base.split('/')[2], base.split('/')[-1]
    assert provider.call_count == 1  # Upload background wake, before session end.
    assert provider.call_args.args[2] == 'batch_findings'
    settings.azure_openai_evaluation_deployment = 'changed-deployment'
    assert api.get(f'/sessions/{sid}/evaluation').status_code == 404
    api.post(f'/sessions/{sid}/end').raise_for_status()
    api.put(f'/sessions/{sid}/upload-manifest', json={
        'audio_turn_ids': [], 'transcript_turn_ids': [tid], 'agent_transcripts': []}).raise_for_status()
    response = api.post(f'/sessions/{sid}/evaluation')
    assert response.status_code == 202
    assert response.json()['transcript_status'] == 'completed'
    assert response.json()['deployment'] == 'test-text'
    assert response.headers['retry-after'] == '5'
    completed = api.post(f'/sessions/{sid}/evaluation')
    assert completed.status_code == 201 and completed.json()['status'] == 'completed'
    assert provider.call_count == 2  # Existing window + final aggregation only.


def test_late_arrival_changes_plan_and_cannot_hide_turns(settings, monkeypatch):
    configured(settings)
    provider = Mock(side_effect=fake_provider)
    monkeypatch.setattr(batches, '_provider_result', provider)
    data = source(2, 12_000)
    finish(settings, 'session', data)
    old = provider.call_count
    late = source(1, 300)['learner_transcripts'][0]
    late['start_ms'] = 1
    data['learner_transcripts'].append(late)
    finish(settings, 'session', data)
    assert provider.call_count > old
    final = json.loads(provider.call_args.args[0])
    assert final['coverage']['learner_characters'] == 24_300


def test_failure_never_blocks_capture_and_explicit_retry(learner_turn, monkeypatch):
    api, settings, base, transcript = learner_turn
    configured(settings)
    monkeypatch.setattr(batches, 'TRIGGER_BYTES', 1)
    provider = Mock(side_effect=httpx.ReadTimeout('private diagnostics'))
    monkeypatch.setattr(batches, '_provider_result', provider)
    assert api.put(base + '/transcript', json=transcript).status_code == 201
    sid = base.split('/')[2]
    batches.wake(settings, sid, ACCOUNT)
    assert provider.call_count == 1  # No unbounded automatic retries.
    provider.side_effect = fake_provider
    finish(settings, sid, batches.live_source(settings, sid, ACCOUNT))
    assert provider.call_count == 3  # Retry failed window, aggregate.


def test_concurrent_job_claim_and_stale_fencing(settings, monkeypatch):
    configured(settings)
    data = source(1, 100)
    config = batches.plan_config(settings, 'session')
    payload = batches.windows(data, config)[0]
    started, release = Event(), Event()
    def blocked(*args):
        started.set()
        assert release.wait(5)
        return findings(payload)
    monkeypatch.setattr(batches, '_provider_result', blocked)
    args = (settings, 'session', config, 'batch_findings', payload, batches.BATCH_INSTRUCTIONS, BatchFindings)
    with ThreadPoolExecutor(max_workers=2) as pool:
        future = pool.submit(batches.job, *args)
        assert started.wait(5)
        assert batches.job(*args) == (None, False)
        # Simulate stale lease takeover; the old worker must not publish.
        with sqlite3.connect(settings.database_path) as db:
            db.execute("UPDATE evaluation_batch_jobs SET lease='new-worker'")
        release.set()
        assert future.result() == (None, True)
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute('SELECT result FROM evaluation_batch_jobs').fetchone()[0] is None


def test_invalid_selection_and_unsupported_scores():
    payload = {'observations': [{'id': 'g', 'category': 'grammar'}], 'corrections': []}
    with pytest.raises(ValueError):
        batches.validate_selection(EvidenceSelection(observation_ids=['invented'], correction_ids=[]), payload)
    report = SessionAggregation(summary='Summary', grammar={'score': 4, 'feedback': 'Grammar'},
        vocabulary={'score': 4, 'feedback': 'Unsupported'}, coherence={'score': None, 'feedback': 'Sparse'},
        strengths=['One'], next_steps=['Two'], observation_ids=['g'], correction_ids=[])
    with pytest.raises(ValueError, match='Unsupported'):
        batches.validate_selection(report, payload)


def test_work_limits_and_context_reject_before_calls(settings, monkeypatch):
    configured(settings)
    provider = Mock(side_effect=fake_provider)
    monkeypatch.setattr(batches, '_provider_result', provider)
    monkeypatch.setattr(batches, 'MAX_WINDOWS', 1)
    with pytest.raises(batches.WorkLimit):
        batches.advance(settings, 'session', source(10), final=True)
    provider.assert_not_called()
    config = batches.configuration(settings)
    config['capacity'] = 1000
    with pytest.raises(ContextLimit):
        batches.windows(source(), config)


def test_timer_resumes_active_work(learner_turn, monkeypatch):
    api, settings, base, transcript = learner_turn
    configured(settings)
    monkeypatch.setattr(batches, 'TRIGGER_BYTES', 1)
    # Lose the initial wake, then discover stored text through the scheduled scan.
    monkeypatch.setattr('app.main.wake', lambda *args: None)
    api.put(base + '/transcript', json=transcript).raise_for_status()
    provider = Mock(side_effect=fake_provider)
    monkeypatch.setattr(batches, '_provider_result', provider)
    batches.resume_pending(settings)
    assert provider.call_count == 1


def test_more_than_200000_bytes_completes_through_api(learner_turn, monkeypatch):
    api, settings, base, _ = learner_turn
    sid = base.split('/')[2]
    turns = []
    for i in range(12):
        turn = str(uuid4())
        turns.append(turn)
        api.put(f'/sessions/{sid}/learner-turns/{turn}/transcript', json={
            'text': 'A' * 19_000, 'start_ms': i * 1000, 'end_ms': i * 1000 + 900}).raise_for_status()
    api.post(f'/sessions/{sid}/end').raise_for_status()
    api.put(f'/sessions/{sid}/upload-manifest', json={
        'audio_turn_ids': [], 'transcript_turn_ids': turns, 'agent_transcripts': []}).raise_for_status()
    configured(settings)
    mock = Mock(side_effect=fake_provider)
    monkeypatch.setattr(batches, '_provider_result', mock)
    for _ in range(100):
        before = mock.call_count
        response = api.post(f'/sessions/{sid}/evaluation')
        assert response.status_code in (201, 202), response.text
        assert mock.call_count - before <= 1
        if response.status_code == 201:
            break
    else:
        pytest.fail('Long-session report never completed')
    assert response.json()['status'] == 'completed'
    with sqlite3.connect(settings.database_path) as db:
        snapshot = db.execute('SELECT snapshot FROM session_evaluations').fetchone()[0]
    assert len(snapshot.encode()) > 200_000
    previous = mock.call_count
    assert api.post(f'/sessions/{sid}/evaluation').status_code == 200
    assert mock.call_count == previous


def test_storage_byte_limit_exact_and_multibyte(ready_evaluation, monkeypatch):
    from app.storage import evaluations
    api, settings, url = ready_evaluation
    sid = url.split('/')[2]
    # Measure the canonical serializer used by reservation, excluding derived context.
    outcome, record, snapshot = evaluations.evaluation_record(settings.database_path, sid, ACCOUNT, 'text')
    canonical = json.loads(snapshot)
    canonical.pop('conversation_context')
    size = len(json.dumps(canonical, sort_keys=True, ensure_ascii=False).encode())
    with sqlite3.connect(settings.database_path) as db:
        db.execute('DELETE FROM session_evaluations')
    monkeypatch.setattr(evaluations, 'MAX_SNAPSHOT_BYTES', size)
    assert evaluations.evaluation_record(settings.database_path, sid, ACCOUNT, 'text')[0] == 'reserved'
    with sqlite3.connect(settings.database_path) as db:
        db.execute('DELETE FROM session_evaluations')
    monkeypatch.setattr(evaluations, 'MAX_SNAPSHOT_BYTES', size - 1)
    assert evaluations.evaluation_record(settings.database_path, sid, ACCOUNT, 'text')[0] == 'too_large'


def test_claim_budget_and_session_concurrency(settings, monkeypatch):
    configured(settings)
    config = batches.plan_config(settings, 'session')
    payload = batches.windows(source(1, 100), config)[0]
    with sqlite3.connect(settings.database_path) as db:
        db.execute('UPDATE evaluation_batch_plans SET calls=?', (batches.MAX_CALLS,))
    with pytest.raises(batches.WorkLimit):
        batches.job(settings, 'session', config, 'batch_findings', payload,
                    batches.BATCH_INSTRUCTIONS, BatchFindings)


def test_corrections_restored_from_validated_index(settings, monkeypatch):
    configured(settings)
    def provider(payload, instructions, name, model, deployment, config):
        data = json.loads(payload)
        if model is BatchFindings:
            part = data['sources'][0]
            return BatchFindings(observations=[], corrections=[{
                'source_id': part['source_id'], 'start_char': 2, 'end_char': 4,
                'original': 'go', 'improved': 'went', 'explanation': 'Past tense.'}])
        return SessionAggregation(summary='A tense correction is available.',
            grammar={'score': None, 'feedback': 'Sparse observation evidence.'},
            vocabulary={'score': None, 'feedback': 'Sparse evidence.'},
            coherence={'score': None, 'feedback': 'Sparse evidence.'},
            strengths=['Meaning is understandable.'], next_steps=['Use past tense for yesterday.'],
            observation_ids=[], correction_ids=[data['corrections'][0]['id']])
    monkeypatch.setattr(batches, '_provider_result', provider)
    data = source(1, 10)
    data['learner_transcripts'][0]['text'] = 'I go yesterday.'
    result, _ = finish(settings, 'session', data)
    correction = result.corrections[0]
    assert correction.turn_id == data['learner_transcripts'][0]['turn_id']
    assert correction.original == 'go' and correction.improved == 'went'


def test_actual_10mib_multibyte_boundary(ready_evaluation):
    from app.storage.evaluations import evaluation_record, MAX_SNAPSHOT_BYTES
    api, settings, url = ready_evaluation
    sid = url.split('/')[2]
    _, _, raw = evaluation_record(settings.database_path, sid, ACCOUNT, 'text')
    data = json.loads(raw)
    data.pop('conversation_context')
    text = data['learner_transcripts'][0]['text']
    overhead = len(json.dumps(data, sort_keys=True, ensure_ascii=False).encode()) - len(text.encode())
    needed = MAX_SNAPSHOT_BYTES - overhead
    # Exercise storage accounting independently of per-upload validation.
    transcript = dict(data['learner_transcripts'][0])
    transcript.pop('turn_id')
    transcript['text'] = '你' * (needed // 3) + 'A' * (needed % 3)
    with sqlite3.connect(settings.database_path) as db:
        db.execute('DELETE FROM session_evaluations')
        db.execute('UPDATE learner_turns SET transcript=? WHERE session_id=?',
                   (json.dumps(transcript, ensure_ascii=False), sid))
    assert evaluation_record(settings.database_path, sid, ACCOUNT, 'text')[0] == 'reserved'
    transcript['text'] += 'A'
    with sqlite3.connect(settings.database_path) as db:
        db.execute('DELETE FROM session_evaluations')
        db.execute('UPDATE learner_turns SET transcript=? WHERE session_id=?',
                   (json.dumps(transcript, ensure_ascii=False), sid))
    assert evaluation_record(settings.database_path, sid, ACCOUNT, 'text')[0] == 'too_large'


def test_synthesis_uses_same_work_budget_and_retains_transcript(ready_speech_evaluation):
    api, settings, url = ready_speech_evaluation
    sid = url.split('/')[2]
    batches.plan_config(settings, sid)
    with sqlite3.connect(settings.database_path) as db:
        db.execute('UPDATE evaluation_batch_plans SET calls=?', (batches.MAX_CALLS,))
    failed = api.post(url)
    assert failed.status_code == 422
    saved = api.get(url).json()
    assert saved['transcript_status'] == 'completed'
    assert saved['error_code'] == 'evaluation_work_limit_exceeded'
    with sqlite3.connect(settings.database_path) as db:
        db.execute('UPDATE evaluation_batch_plans SET calls=?', (batches.MAX_CALLS - 1,))
    assert api.post(url).status_code == 201
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute('SELECT calls FROM evaluation_batch_plans').fetchone()[0] == batches.MAX_CALLS


def test_unique_quote_offsets_are_resolved_but_ambiguous_quotes_fail():
    payload = {'sources': [{'source_id': 's', 'text': 'I go yesterday.'}]}
    result = BatchFindings(observations=[], corrections=[{
        'source_id': 's', 'start_char': 0, 'end_char': 99, 'original': 'go',
        'improved': 'went', 'explanation': 'Past tense.'}])
    batches.validate_findings(result, payload)
    assert (result.corrections[0].start_char, result.corrections[0].end_char) == (2, 4)
    payload['sources'][0]['text'] = 'I go, then go again.'
    result.corrections[0].start_char, result.corrections[0].end_char = 0, 99
    with pytest.raises(ValueError, match='Invalid source'):
        batches.validate_findings(result, payload)

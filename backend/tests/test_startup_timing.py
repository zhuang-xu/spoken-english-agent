"""Startup traces cross worker threads and never expose request payloads."""
import logging
from concurrent.futures import ThreadPoolExecutor
from contextvars import copy_context

import pytest

from app.startup_timing import StartupTiming, current, timed


def test_session_response_contains_real_service_stage_timings(client, caplog):
    api, _ = client
    with caplog.at_level(logging.INFO):
        first = api.post('/sessions', json={
            'speaking_goal': 'Private speaking goal', 'level': 'B1',
            'preferred_topic': None, 'session_duration_minutes': 10})
    assert first.status_code == 201
    header = first.headers['server-timing']
    for name in ['reservation', 'azure_credential', 'activation', 'app_total']:
        assert f'{name};dur=' in header
    trace = first.headers['x-startup-trace-id']
    assert len(trace) == 32
    messages = '\n'.join(r.getMessage() for r in caplog.records if r.name.startswith('spoken.'))
    assert f'trace={trace}' in messages
    for private in ['Private speaking goal', 'server-secret', 'ephemeral-token']:
        assert private not in messages and private not in header
    assert 'server-timing' not in api.get('/health').headers
    assert current.get() is None


def test_failure_still_has_elapsed_stage_and_no_exception_description(caplog):
    @timed('azure_credential')
    def failing():
        raise ValueError('secret provider payload')
    timing = StartupTiming()
    token = current.set(timing)
    try:
        with caplog.at_level(logging.INFO, logger='spoken.startup'):
            with pytest.raises(ValueError):
                failing()
        assert timing.durations['azure_credential'] >= 0
        assert 'success=False' in caplog.text
        assert 'secret provider payload' not in caplog.text
    finally:
        current.reset(token)


def test_parallel_request_contexts_do_not_share_timings():
    @timed('account_lookup')
    def work():
        return current.get().trace
    def request():
        timing = StartupTiming()
        token = current.set(timing)
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                observed = pool.submit(copy_context().run, work).result()
            assert observed == timing.trace
            assert set(timing.durations) == {'account_lookup'}
            return timing.trace
        finally:
            current.reset(token)
    with ThreadPoolExecutor(max_workers=2) as pool:
        traces = list(pool.map(lambda _: request(), range(2)))
    assert traces[0] != traces[1]

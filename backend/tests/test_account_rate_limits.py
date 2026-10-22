"""Shared account quotas protect provider-backed routes across app workers."""
from concurrent.futures import ThreadPoolExecutor

from fastapi import HTTPException

from app.auth import enforce_account_limits


def test_account_quota_is_shared_across_concurrent_requests(settings):
    def request():
        try:
            enforce_account_limits(settings.database_path, 'alice', creating_session=False,
                                   requests_per_minute=5, sessions_per_hour=2, now=120)
            return 200
        except HTTPException as error:
            assert error.headers == {'Retry-After': '60'}
            return error.status_code

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: request(), range(8)))
    assert results.count(200) == 5
    assert results.count(429) == 3
    enforce_account_limits(settings.database_path, 'bob', creating_session=False,
                           requests_per_minute=5, sessions_per_hour=2, now=120)
    enforce_account_limits(settings.database_path, 'alice', creating_session=False,
                           requests_per_minute=5, sessions_per_hour=2, now=180)


def test_session_quota_blocks_starts_but_allows_other_requests(settings):
    for now in (120, 121):
        enforce_account_limits(settings.database_path, 'alice', creating_session=True,
                               requests_per_minute=20, sessions_per_hour=2, now=now)
    try:
        enforce_account_limits(settings.database_path, 'alice', creating_session=True,
                               requests_per_minute=20, sessions_per_hour=2, now=122)
    except HTTPException as error:
        assert error.status_code == 429
        assert error.headers == {'Retry-After': str(3600 - 122)}
    else:
        raise AssertionError('Third session start should be limited')
    enforce_account_limits(settings.database_path, 'alice', creating_session=False,
                           requests_per_minute=20, sessions_per_hour=2, now=122)


def test_evaluation_quota_is_independent_of_session_quota(settings):
    enforce_account_limits(settings.database_path, 'alice', creating_session=False,
                           requesting_evaluation=True, requests_per_minute=20,
                           sessions_per_hour=1, evaluations_per_hour=1, now=120)
    try:
        enforce_account_limits(settings.database_path, 'alice', creating_session=False,
                               requesting_evaluation=True, requests_per_minute=20,
                               sessions_per_hour=1, evaluations_per_hour=1, now=121)
    except HTTPException as error:
        assert error.status_code == 429
    else:
        raise AssertionError('Second evaluation should be limited')
    enforce_account_limits(settings.database_path, 'alice', creating_session=True,
                           requests_per_minute=20, sessions_per_hour=1, now=121)


def test_checkpoint_auth_reuses_evaluation_quota(ready_evaluation, monkeypatch):
    from app import auth
    from app.storage.evaluations import evaluation_record
    from starlette.requests import Request
    api, settings, url = ready_evaluation
    account = '00000000-0000-4000-8000-000000000001'
    sid = url.split('/')[2]
    settings.account_evaluations_per_hour = 1
    monkeypatch.setattr(auth, '_platform_principal', lambda *args: object())
    monkeypatch.setattr(auth, 'account_for_identity', lambda *args: account)
    request = Request({'type': 'http', 'method': 'POST', 'path': url,
                       'headers': [], 'path_params': {'session_id': sid}})
    assert auth.current_account(request, settings) == account
    assert evaluation_record(settings.database_path, sid, account, 'text')[0] == 'reserved'
    for _ in range(25):
        assert auth.current_account(request, settings) == account
    another = Request({'type': 'http', 'method': 'POST', 'path': '/sessions/other/evaluation',
                       'headers': [], 'path_params': {'session_id': 'other'}})
    try:
        auth.current_account(another, settings)
    except HTTPException as error:
        assert error.status_code == 429
    else:
        raise AssertionError('A new session evaluation must still consume quota')

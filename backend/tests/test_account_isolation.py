"""Ownership checks at the HTTP and migration boundaries."""
import sqlite3
from uuid import uuid4

from fastapi.testclient import TestClient

from app.auth import current_account
from app.config import get_settings
from app.main import app

A = '00000000-0000-4000-8000-00000000000a'
B = '00000000-0000-4000-8000-00000000000b'
PREFERENCES = {'speaking_goal': 'Practice interviews', 'level': 'B1',
               'preferred_topic': 'work', 'session_duration_minutes': 15}


def test_every_session_route_is_scoped(settings, mock_openai_post, monkeypatch):
    active = {'account': A}
    monkeypatch.setitem(app.dependency_overrides, get_settings, lambda: settings)
    monkeypatch.setitem(app.dependency_overrides, current_account, lambda: active['account'])
    settings.azure_openai_evaluation_deployment = 'evaluation'
    with TestClient(app) as api:
        first = api.post('/sessions', json=PREFERENCES, headers={'Idempotency-Key': 'same'})
        assert first.status_code == 201
        sid = first.json()['session']['id']
        turn = str(uuid4())
        base = f'/sessions/{sid}'
        active['account'] = B
        assert api.get('/me').json()['account_id'] == B
        second = api.post('/sessions', json=PREFERENCES, headers={'Idempotency-Key': 'same'})
        assert second.status_code == 201
        assert second.json()['session']['id'] != sid
        before = mock_openai_post.call_count
        manifest = {'audio_turn_ids': [], 'transcript_turn_ids': [], 'agent_transcripts': []}
        requests = [
            api.post(base + '/heartbeat'), api.post(base + '/end'),
            api.get(base + '/data-status'), api.put(base + '/upload-manifest', json=manifest),
            api.put(base + f'/learner-turns/{turn}/transcript', json={
                'text': 'Hello', 'start_ms': 0, 'end_ms': 100}),
            api.put(base + f'/learner-turns/{turn}/audio', content=b'abc',
                    headers={'Content-Type': 'audio/wav'}),
            api.put(base + '/agent-items/item_1/transcripts/0', json={
                'text': 'Hello', 'response_id': 'response_1'}),
            api.get(base + '/evaluation'), api.post(base + '/evaluation'),
        ]
        assert [response.status_code for response in requests] == [404] * len(requests)
        assert mock_openai_post.call_count == before
        active['account'] = A
        assert api.get(base + '/data-status').status_code == 200
        assert api.post(base + '/heartbeat').status_code == 200


def test_legacy_rows_remain_unowned(settings, mock_openai_post, monkeypatch):
    with sqlite3.connect(settings.database_path) as db:
        db.execute('''CREATE TABLE practice_sessions (
            id TEXT PRIMARY KEY, status TEXT NOT NULL, created_at TEXT NOT NULL,
            preferences TEXT NOT NULL, provider_session_id TEXT, idempotency_key TEXT)''')
        db.execute('CREATE UNIQUE INDEX session_idempotency_key ON practice_sessions(idempotency_key)')
        db.execute('INSERT INTO practice_sessions VALUES (?, ?, ?, ?, ?, ?)',
                   (str(uuid4()), 'active', '2026-01-01T00:00:00+00:00',
                    __import__('json').dumps(PREFERENCES), None, 'same'))
        old_id = db.execute('SELECT id FROM practice_sessions').fetchone()[0]
    monkeypatch.setitem(app.dependency_overrides, get_settings, lambda: settings)
    monkeypatch.setitem(app.dependency_overrides, current_account, lambda: A)
    with TestClient(app) as api:
        assert api.get(f'/sessions/{old_id}/data-status').status_code == 404
        assert api.post('/sessions', json=PREFERENCES,
                        headers={'Idempotency-Key': 'same'}).status_code == 201
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute('SELECT owner_account_id FROM practice_sessions WHERE id=?',
                          (old_id,)).fetchone()[0] is None


def test_authentication_rejects_forged_and_wrong_tokens(settings, monkeypatch):
    import base64
    import json
    from datetime import datetime, timedelta, timezone
    from types import SimpleNamespace
    import jwt
    from cryptography.hazmat.primitives.asymmetric import rsa
    from app import auth

    tenant = '11111111-1111-4111-8111-111111111111'
    client_id = '22222222-2222-4222-8222-222222222222'
    settings.entra_tenant_id = tenant
    settings.entra_api_audience = '33333333-3333-4333-8333-333333333333'
    settings.entra_scope = 'practice.readwrite'
    settings.entra_allowed_client_ids = client_id
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    monkeypatch.setattr(auth, '_entra_keys', lambda issuer: SimpleNamespace(
        get_signing_key_from_jwt=lambda token: SimpleNamespace(key=private_key.public_key())))
    monkeypatch.setitem(app.dependency_overrides, get_settings, lambda: settings)
    app.dependency_overrides.pop(current_account, None)
    now = datetime.now(timezone.utc)
    claims = {'iss': f'https://login.microsoftonline.com/{tenant}/v2.0',
              'ver': '2.0', 'aud': settings.entra_api_audience, 'tid': tenant,
              'oid': '44444444-4444-4444-8444-444444444444', 'azp': client_id,
              'scp': settings.entra_scope, 'iat': now, 'nbf': now,
              'exp': now + timedelta(minutes=5)}
    def signed(**changes):
        return jwt.encode({**claims, **changes}, private_key, algorithm='RS256')
    forged = base64.b64encode(json.dumps({'auth_typ': 'aad', 'claims': [
        {'typ': 'tid', 'val': tenant}, {'typ': 'oid', 'val': claims['oid']}]}).encode()).decode()
    with TestClient(app) as api:
        assert api.get('/me').status_code == 401
        assert api.get('/me', headers={'X-MS-CLIENT-PRINCIPAL': forged}).status_code == 401
        for token in (signed(exp=now - timedelta(seconds=1)),
                      signed(aud='another-api'), signed(tid=str(uuid4())),
                      jwt.encode(claims, 'wrong-secret', algorithm='HS256')):
            assert api.get('/me', headers={'Authorization': f'Bearer {token}'}).status_code == 401
        for token in (signed(scp='another.scope'), signed(azp=str(uuid4()))):
            assert api.get('/me', headers={'Authorization': f'Bearer {token}'}).status_code == 403
        valid = signed()
        first = api.get('/me', headers={'Authorization': f'Bearer {valid}'})
        assert first.status_code == 200
        assert api.get('/me', headers={'Authorization': f'Bearer {valid}'}).json() == first.json()


def test_platform_and_bearer_resolve_same_account(settings, monkeypatch):
    import base64
    import json
    from app import auth
    from types import SimpleNamespace
    from datetime import datetime, timedelta, timezone
    import jwt
    from cryptography.hazmat.primitives.asymmetric import rsa

    tenant = '11111111-1111-4111-8111-111111111111'
    object_id = '44444444-4444-4444-8444-444444444444'
    settings.entra_tenant_id = tenant
    settings.entra_api_audience = '33333333-3333-4333-8333-333333333333'
    settings.entra_scope = 'practice.readwrite'
    settings.trust_azure_platform_auth = True
    monkeypatch.setenv('WEBSITE_SITE_NAME', 'spoken-test')
    monkeypatch.setenv('WEBSITE_AUTH_ENABLED', 'true')
    monkeypatch.setitem(app.dependency_overrides, get_settings, lambda: settings)
    app.dependency_overrides.pop(current_account, None)
    principal = base64.b64encode(json.dumps({'auth_typ': 'aad', 'claims': [
        {'typ': 'http://schemas.microsoft.com/identity/claims/tenantid', 'val': tenant},
        {'typ': 'http://schemas.microsoft.com/identity/claims/objectidentifier', 'val': object_id},
    ]}).encode()).decode()
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    monkeypatch.setattr(auth, '_entra_keys', lambda issuer: SimpleNamespace(
        get_signing_key_from_jwt=lambda token: SimpleNamespace(key=private_key.public_key())))
    now = datetime.now(timezone.utc)
    token = jwt.encode({'iss': f'https://login.microsoftonline.com/{tenant}/v2.0',
        'ver': '2.0', 'aud': settings.entra_api_audience, 'tid': tenant, 'oid': object_id,
        'scp': settings.entra_scope, 'iat': now, 'nbf': now, 'exp': now + timedelta(minutes=5)},
        private_key, algorithm='RS256')
    with TestClient(app) as api:
        browser = api.get('/me', headers={'X-MS-CLIENT-PRINCIPAL': principal})
        native = api.get('/me', headers={'Authorization': f'Bearer {token}'})
        assert browser.status_code == native.status_code == 200
        assert browser.json() == native.json()


def test_expected_account_rejects_cookie_switch_before_session_creation(settings, mock_openai_post, monkeypatch):
    monkeypatch.setitem(app.dependency_overrides, get_settings, lambda: settings)
    # Exercise the real dependency to verify the expected-account assertion.
    from app.auth import Identity, account_for_identity
    tenant = '11111111-1111-4111-8111-111111111111'
    settings.entra_tenant_id = tenant
    settings.trust_azure_platform_auth = True
    monkeypatch.setenv('WEBSITE_SITE_NAME', 'spoken-test')
    monkeypatch.setenv('WEBSITE_AUTH_ENABLED', 'true')
    import base64, json
    def principal(oid):
        return base64.b64encode(json.dumps({'auth_typ': 'aad', 'claims': [
            {'typ': 'tid', 'val': tenant}, {'typ': 'oid', 'val': oid}]}).encode()).decode()
    a_oid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    b_oid = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    expected = account_for_identity(settings.database_path, Identity(tenant, a_oid))
    with TestClient(app) as api:
        response = api.post('/sessions', json=PREFERENCES, headers={
            'X-MS-CLIENT-PRINCIPAL': principal(b_oid), 'X-Expected-Account-ID': expected})
    assert response.status_code == 409
    assert response.headers['X-Account-Changed'] == '1'
    assert mock_openai_post.call_count == 0
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute("SELECT COUNT(*) FROM sqlite_master WHERE name='practice_sessions'").fetchone()[0] == 0


def test_entra_discovery_accepts_real_tenant_key_endpoint(monkeypatch):
    from app import auth
    from types import SimpleNamespace
    issuer = 'https://login.microsoftonline.com/11111111-1111-4111-8111-111111111111/v2.0'
    keys = issuer.removesuffix('/v2.0') + '/discovery/v2.0/keys'
    calls = []
    monkeypatch.setattr(auth.httpx, 'get', lambda url, timeout: SimpleNamespace(
        raise_for_status=lambda: None, json=lambda: {'issuer': issuer, 'jwks_uri': keys}))
    monkeypatch.setattr(auth, 'PyJWKClient', lambda url, **kwargs: calls.append(url) or 'keys')
    auth._entra_keys.cache_clear()
    try:
        assert auth._entra_keys(issuer) == 'keys'
        assert calls == [keys]
    finally:
        auth._entra_keys.cache_clear()


def test_entra_discovery_rejects_foreign_keys_or_issuer(monkeypatch):
    import pytest
    from app import auth
    from types import SimpleNamespace
    issuer = 'https://login.microsoftonline.com/11111111-1111-4111-8111-111111111111/v2.0'
    keys = issuer.removesuffix('/v2.0') + '/discovery/v2.0/keys'
    for document in ({'issuer': issuer, 'jwks_uri': 'https://example.com/keys'},
                     {'issuer': issuer + '/other', 'jwks_uri': keys},
                     {'issuer': issuer, 'jwks_uri': keys + '?redirect=other'},
                     {'issuer': issuer, 'jwks_uri': issuer + '/keys'}):
        monkeypatch.setattr(auth.httpx, 'get', lambda url, timeout: SimpleNamespace(
            raise_for_status=lambda: None, json=lambda: document))
        auth._entra_keys.cache_clear()
        with pytest.raises(ValueError, match='Unexpected Entra metadata'):
            auth._entra_keys(issuer)
    auth._entra_keys.cache_clear()

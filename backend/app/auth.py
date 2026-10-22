"""Resolve verified Entra identities to opaque local accounts."""
import base64
import binascii
from functools import lru_cache
from dataclasses import dataclass
import json
import os
import sqlite3
import time
from uuid import UUID, uuid4

from fastapi import Depends, HTTPException, Request
import httpx
import jwt
from jwt import PyJWKClient

from app.config import Settings, get_settings
from app.storage.database import database_connection


@dataclass(frozen=True)
class Identity:
    tenant_id: str
    object_id: str


def _guid(value):
    try:
        return str(UUID(value))
    except (TypeError, ValueError, AttributeError):
        raise HTTPException(401, 'Invalid identity.') from None


@lru_cache(maxsize=16)
def _entra_keys(issuer: str) -> PyJWKClient:
    metadata = httpx.get(f'{issuer}/.well-known/openid-configuration', timeout=5)
    metadata.raise_for_status()
    document = metadata.json()
    # Entra publishes keys under /<tenant>/discovery/v2.0/keys, not /<tenant>/v2.0/.
    expected_keys = issuer.removesuffix('/v2.0') + '/discovery/v2.0/keys'
    if document.get('issuer') != issuer or document.get('jwks_uri') != expected_keys:
        raise ValueError('Unexpected Entra metadata')
    return PyJWKClient(document['jwks_uri'], cache_jwk_set=True, lifespan=3600)


def _bearer(token: str, settings: Settings) -> Identity:
    if not settings.entra_tenant_id or not settings.entra_api_audience or not settings.entra_scope:
        raise HTTPException(503, 'API authentication is not configured.')
    tenant = _guid(settings.entra_tenant_id)
    issuer = f'https://login.microsoftonline.com/{tenant}/v2.0'
    try:
        key = _entra_keys(issuer).get_signing_key_from_jwt(token)
        claims = jwt.decode(token, key.key, algorithms=['RS256'], audience=settings.entra_api_audience,
                            issuer=issuer, options={'require': ['exp', 'nbf', 'iat', 'iss', 'aud', 'tid', 'oid', 'scp']})
    except (httpx.HTTPError, ValueError, KeyError, jwt.PyJWTError):
        raise HTTPException(401, 'Invalid access token.') from None
    if (claims.get('ver') != '2.0' or claims.get('aud') != settings.entra_api_audience
            or _guid(claims.get('tid')) != tenant or not claims.get('oid')):
        raise HTTPException(401, 'Invalid access token.')
    if settings.entra_scope not in claims['scp'].split():
        raise HTTPException(403, 'API permission is required.')
    allowed = {item.strip() for item in settings.entra_allowed_client_ids.split(',') if item.strip()}
    if allowed and claims.get('azp') not in allowed:
        raise HTTPException(403, 'Client is not permitted.')
    return Identity(tenant, _guid(claims['oid']))


def _platform_principal(request: Request, settings: Settings) -> Identity:
    # Only the Azure front end may inject this header. A local process never trusts it.
    if not (settings.trust_azure_platform_auth and os.environ.get('WEBSITE_SITE_NAME')
            and os.environ.get('WEBSITE_AUTH_ENABLED', '').lower() in ('true', '1')):
        raise HTTPException(401, 'Authentication is required.')
    encoded = request.headers.get('x-ms-client-principal', '')
    if not encoded or len(encoded) > 32768:
        raise HTTPException(401, 'Authentication is required.')
    try:
        principal = json.loads(base64.b64decode(encoded, validate=True))
        if principal.get('auth_typ', '').lower() not in ('aad', 'azureactivedirectory'):
            raise ValueError('Provider')
        claims = {entry['typ']: entry['val'] for entry in principal['claims']}
        tenant = claims.get('tid') or claims.get('http://schemas.microsoft.com/identity/claims/tenantid')
        object_id = claims.get('oid') or claims.get('http://schemas.microsoft.com/identity/claims/objectidentifier')
        tenant = _guid(tenant)
        object_id = _guid(object_id)
    except (ValueError, KeyError, TypeError, binascii.Error):
        raise HTTPException(401, 'Invalid platform identity.') from None
    if tenant != _guid(settings.entra_tenant_id):
        raise HTTPException(403, 'Tenant is not permitted.')
    return Identity(tenant, object_id)


def account_for_identity(database_path: str, identity: Identity) -> str:
    with database_connection(database_path) as db:
        db.execute('BEGIN IMMEDIATE')
        db.execute('''CREATE TABLE IF NOT EXISTS account_identities (
            provider TEXT NOT NULL, tenant_id TEXT NOT NULL, object_id TEXT NOT NULL,
            account_id TEXT NOT NULL UNIQUE,
            PRIMARY KEY (provider, tenant_id, object_id)
        )''')
        key = ('entra', identity.tenant_id, identity.object_id)
        db.execute('INSERT OR IGNORE INTO account_identities VALUES (?, ?, ?, ?)', (*key, str(uuid4())))
        return db.execute('SELECT account_id FROM account_identities WHERE provider=? AND tenant_id=? AND object_id=?', key).fetchone()[0]


def enforce_account_limits(database_path: str, account_id: str, *, creating_session: bool,
                           requesting_evaluation: bool = False,
                           requests_per_minute: int, sessions_per_hour: int,
                           evaluations_per_hour: int = 20,
                           now: int | None = None) -> None:
    """Apply shared, transactional fixed-window quotas before provider work begins."""
    instant = int(time.time()) if now is None else now
    quotas = [('requests', 60, requests_per_minute)]
    if creating_session:
        quotas.append(('session_starts', 3600, sessions_per_hour))
    if requesting_evaluation:
        quotas.append(('evaluations', 3600, evaluations_per_hour))
    with database_connection(database_path) as db:
        db.execute('BEGIN IMMEDIATE')
        db.execute('''CREATE TABLE IF NOT EXISTS account_rate_limits (
            account_id TEXT NOT NULL, bucket TEXT NOT NULL, window_start INTEGER NOT NULL,
            count INTEGER NOT NULL, PRIMARY KEY (account_id, bucket, window_start)
        )''')
        # Expired buckets are safe to discard; each check holds the database write lease.
        db.execute('DELETE FROM account_rate_limits WHERE window_start < ?', (instant - 7200,))
        for bucket, seconds, limit in quotas:
            window = instant // seconds * seconds
            row = db.execute('''SELECT count FROM account_rate_limits
                WHERE account_id=? AND bucket=? AND window_start=?''', (account_id, bucket, window)).fetchone()
            if row and row[0] >= limit:
                raise HTTPException(429, 'Account request limit reached.',
                                    headers={'Retry-After': str(window + seconds - instant)})
        for bucket, seconds, _ in quotas:
            window = instant // seconds * seconds
            db.execute('''INSERT INTO account_rate_limits VALUES (?, ?, ?, 1)
                ON CONFLICT(account_id, bucket, window_start) DO UPDATE SET count=count+1''',
                (account_id, bucket, window))


def current_account(request: Request, settings: Settings = Depends(get_settings)) -> str:
    authorization = request.headers.get('authorization', '')
    if authorization:
        scheme, _, token = authorization.partition(' ')
        if scheme.lower() != 'bearer' or not token or len(token) > 16384:
            raise HTTPException(401, 'Invalid authorization header.')
        identity = _bearer(token, settings)
    else:
        identity = _platform_principal(request, settings)
    try:
        account_id = account_for_identity(settings.database_path, identity)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Account storage is unavailable.') from None
    expected = request.headers.get('x-expected-account-id')
    if expected and expected != account_id:
        raise HTTPException(409, 'The signed-in account changed.',
                            headers={'X-Account-Changed': '1'})
    try:
        requesting_evaluation = request.method == 'POST' and request.url.path.endswith('/evaluation')
        # Checkpoint POSTs resume an existing evaluation, rather than starting a new
        # billable session evaluation. The general request quota still applies.
        if requesting_evaluation:
            sid = request.path_params.get('session_id')
            with database_connection(settings.database_path) as db:
                if db.execute("SELECT 1 FROM sqlite_master WHERE name='session_evaluations'").fetchone():
                    requesting_evaluation = not bool(db.execute(
                        'SELECT 1 FROM session_evaluations e JOIN practice_sessions s ON s.id=e.session_id '
                        'WHERE e.session_id=? AND s.owner_account_id=?', (str(sid), account_id)).fetchone())
        enforce_account_limits(
            settings.database_path, account_id,
            creating_session=request.method == 'POST' and request.url.path == '/sessions',
            requesting_evaluation=requesting_evaluation,
            requests_per_minute=settings.account_requests_per_minute,
            sessions_per_hour=settings.account_sessions_per_hour,
            evaluations_per_hour=settings.account_evaluations_per_hour)
    except (sqlite3.Error, OSError):
        raise HTTPException(503, 'Account storage is unavailable.') from None
    return account_id

"""PostgreSQL connection pooling and versioned application schema."""
from contextlib import contextmanager
import os
import sqlite3
from threading import Lock

import psycopg
from psycopg_pool import ConnectionPool, PoolTimeout

_pools = {}
_pool_lock = Lock()


class PostgresConnection:
    postgresql = True

    def __init__(self, connection):
        self.connection = connection

    def execute(self, query, parameters=None):
        # Shared application queries use qmark bindings and contain no literal question marks.
        if parameters is not None:
            return self.connection.execute(query.replace('?', '%s'), parameters)
        return self.connection.execute(query)


def _pool(dsn):
    with _pool_lock:
        if dsn not in _pools:
            max_size = int(os.environ.get('POSTGRES_POOL_MAX_SIZE', '2'))
            if not 1 <= max_size <= 16:
                raise ValueError('POSTGRES_POOL_MAX_SIZE must be between 1 and 16.')
            _pools[dsn] = ConnectionPool(
                dsn, min_size=0, max_size=max_size, timeout=5, max_waiting=32, max_idle=60,
                kwargs={'connect_timeout': 5, 'prepare_threshold': None,
                        'application_name': 'spoken_agents',
                        'options': '-c statement_timeout=10000 -c lock_timeout=5000'},
                check=ConnectionPool.check_connection, open=True,
            )
        return _pools[dsn]


@contextmanager
def postgres_connection(dsn):
    try:
        with _pool(dsn).connection() as connection:
            yield PostgresConnection(connection)
    except (psycopg.Error, PoolTimeout):
        # Preserve the storage error contract without exposing SQL, data or connection details.
        raise sqlite3.OperationalError('PostgreSQL storage is unavailable.') from None


MIGRATIONS = ('''
    CREATE TABLE account_identities (
        provider TEXT NOT NULL, tenant_id TEXT NOT NULL, object_id TEXT NOT NULL,
        account_id TEXT NOT NULL UNIQUE, PRIMARY KEY (provider, tenant_id, object_id)
    );
    CREATE TABLE account_rate_limits (
        account_id TEXT NOT NULL, bucket TEXT NOT NULL, window_start BIGINT NOT NULL,
        count INTEGER NOT NULL, PRIMARY KEY (account_id, bucket, window_start)
    );
    CREATE INDEX account_rate_limits_expiry ON account_rate_limits (window_start);
    CREATE TABLE practice_sessions (
        id TEXT PRIMARY KEY, status TEXT NOT NULL, created_at TEXT NOT NULL,
        preferences TEXT NOT NULL, provider_session_id TEXT, ended_at TEXT,
        last_activity_at TEXT NOT NULL, end_reason TEXT, idempotency_key TEXT,
        upload_manifest TEXT, owner_account_id TEXT
    );
    CREATE UNIQUE INDEX session_owner_idempotency_key ON practice_sessions (owner_account_id, idempotency_key)
        WHERE owner_account_id IS NOT NULL AND idempotency_key IS NOT NULL;
    CREATE INDEX active_session_activity ON practice_sessions (last_activity_at) WHERE status='active';
    CREATE INDEX creating_session_age ON practice_sessions (created_at) WHERE status='creating';
    CREATE TABLE learner_turns (
        session_id TEXT NOT NULL REFERENCES practice_sessions(id), turn_id TEXT NOT NULL,
        audio BYTEA, media_type TEXT, audio_received_at TEXT, transcript TEXT, transcript_received_at TEXT,
        PRIMARY KEY (session_id, turn_id)
    );
    CREATE TABLE learner_recordings (
        session_id TEXT NOT NULL, turn_id TEXT NOT NULL, object_key TEXT NOT NULL UNIQUE,
        sha256 TEXT NOT NULL, size_bytes INTEGER NOT NULL, PRIMARY KEY (session_id, turn_id),
        FOREIGN KEY (session_id, turn_id) REFERENCES learner_turns(session_id, turn_id)
    );
    CREATE TABLE agent_transcripts (
        session_id TEXT NOT NULL REFERENCES practice_sessions(id), item_id TEXT NOT NULL,
        content_index INTEGER NOT NULL, transcript TEXT NOT NULL, received_at TEXT NOT NULL,
        PRIMARY KEY (session_id, item_id, content_index)
    );
    CREATE TABLE speech_assessments (
        session_id TEXT NOT NULL, turn_id TEXT NOT NULL, audio_sha256 TEXT NOT NULL,
        version TEXT NOT NULL, result TEXT NOT NULL,
        PRIMARY KEY (session_id, turn_id, audio_sha256, version)
    );
    CREATE TABLE session_evaluations (
        session_id TEXT PRIMARY KEY REFERENCES practice_sessions(id), snapshot TEXT NOT NULL, record TEXT NOT NULL
    );
    CREATE TABLE evaluation_batch_plans (
        session_id TEXT PRIMARY KEY REFERENCES practice_sessions(id), config TEXT NOT NULL,
        calls INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE evaluation_batch_jobs (
        session_id TEXT NOT NULL REFERENCES evaluation_batch_plans(session_id), job_id TEXT NOT NULL,
        kind TEXT NOT NULL, payload TEXT NOT NULL, result TEXT, lease TEXT, leased_at DOUBLE PRECISION,
        failures INTEGER NOT NULL DEFAULT 0, error_code TEXT, PRIMARY KEY (session_id, job_id)
    );
    CREATE TABLE spoken_import_receipts (id TEXT PRIMARY KEY, counts TEXT NOT NULL);
''',)


def migrate(connection):
    """Run with the schema owner on a raw psycopg connection before serving traffic."""
    with connection.transaction():
        connection.execute('SELECT pg_advisory_xact_lock(7365042)')
        connection.execute('CREATE TABLE IF NOT EXISTS spoken_schema_version (version INTEGER PRIMARY KEY)')
        versions = [row[0] for row in connection.execute('SELECT version FROM spoken_schema_version ORDER BY version')]
        if versions != list(range(1, len(versions) + 1)) or len(versions) > len(MIGRATIONS):
            raise ValueError('Unrecognized PostgreSQL schema version.')
        for version, ddl in enumerate(MIGRATIONS[len(versions):], start=len(versions) + 1):
            connection.execute(ddl)
            connection.execute('INSERT INTO spoken_schema_version VALUES (%s)', (version,))


def verify_schema(dsn):
    with postgres_connection(dsn) as connection:
        version = connection.execute('SELECT max(version) FROM spoken_schema_version').fetchone()[0]
        if version != len(MIGRATIONS):
            raise sqlite3.OperationalError('PostgreSQL schema version does not match the application.')

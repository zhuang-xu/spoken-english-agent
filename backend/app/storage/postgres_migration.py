"""Import SQLite storage into a pre-migrated PostgreSQL schema."""
import hashlib
import json

from psycopg import sql

TABLES = (
    'account_identities', 'account_rate_limits', 'practice_sessions', 'learner_turns',
    'learner_recordings', 'agent_transcripts', 'speech_assessments', 'session_evaluations',
    'evaluation_batch_plans', 'evaluation_batch_jobs',
)
LIFECYCLE_DEFAULTS = {
    'ended_at': 'NULL', 'last_activity_at': 'created_at', 'end_reason': 'NULL',
    'idempotency_key': 'NULL', 'upload_manifest': 'NULL', 'owner_account_id': 'NULL',
}


def row_digest(row):
    values = [value if not isinstance(value, bytes) else {'bytes_sha256': hashlib.sha256(value).hexdigest()}
              for value in row]
    data = json.dumps(values, ensure_ascii=False, separators=(',', ':')).encode()
    return int.from_bytes(hashlib.sha256(data).digest(), 'big')


def source_rows(source, table, columns):
    source_columns = {row[1] for row in source.execute(f'PRAGMA table_info({table})')}
    if not source_columns:
        return ()
    if source_columns - set(columns):
        raise ValueError(f'Unexpected SQLite columns in {table}.')
    select = []
    for column in columns:
        if column in source_columns:
            expression = f'"{column}"'
            if table == 'practice_sessions' and column == 'last_activity_at':
                expression = 'COALESCE(last_activity_at, created_at)'
        elif table == 'practice_sessions' and column in LIFECYCLE_DEFAULTS:
            expression = LIFECYCLE_DEFAULTS[column]
        else:
            raise ValueError(f'Missing SQLite column in {table}.')
        if table == 'practice_sessions' and column == 'end_reason':
            expression = f"COALESCE({expression}, CASE WHEN status='ended' THEN 'client_requested' END)"
        select.append(expression)
    return source.execute(f'SELECT {", ".join(select)} FROM "{table}"')


def import_sqlite(source, target, *, receipt_id=None):
    if source.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
        raise ValueError('SQLite integrity check failed.')
    source_tables = {row[0] for row in source.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if source_tables - set(TABLES) - {'sqlite_sequence'}:
        raise ValueError('Unexpected tables in the SQLite source.')
    counts = {}
    with target.transaction():
        target.execute('SELECT pg_advisory_xact_lock(7365042)')
        if receipt_id is not None:
            receipt = target.execute('SELECT counts FROM spoken_import_receipts WHERE id=%s', (receipt_id,)).fetchone()
            if receipt:
                return json.loads(receipt[0])
        for table in TABLES:
            name = sql.Identifier(table)
            result = target.execute(sql.SQL('SELECT * FROM {} LIMIT 0').format(name))
            columns = [column.name for column in result.description]
            if target.execute(sql.SQL('SELECT 1 FROM {} LIMIT 1').format(name)).fetchone():
                raise ValueError('Import requires an empty application schema.')
            count = digest = 0
            with target.cursor() as cursor, cursor.copy(sql.SQL('COPY {} ({}) FROM STDIN').format(
                    name, sql.SQL(', ').join(map(sql.Identifier, columns)))) as writer:
                for row in source_rows(source, table, columns):
                    writer.write_row(row)
                    digest ^= row_digest(row)
                    count += 1
            copied = copied_digest = 0
            with target.cursor(name='verify_import') as cursor:
                cursor.execute(sql.SQL('SELECT * FROM {}').format(name))
                for row in cursor:
                    copied_digest ^= row_digest(row)
                    copied += 1
            if (count, digest) != (copied, copied_digest):
                raise ValueError(f'Import verification failed for {table}.')
            counts[table] = count
        if receipt_id is not None:
            target.execute('INSERT INTO spoken_import_receipts VALUES (%s, %s)', (receipt_id, json.dumps(counts)))
    return counts



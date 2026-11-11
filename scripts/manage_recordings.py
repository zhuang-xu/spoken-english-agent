"""Backfill legacy recording bytes, compact SQLite, or remove orphan recording objects."""
import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sqlite3
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))

from app.config import get_settings
from app.storage.database import database_connection
from app.storage.recordings import Recording, RecordingStore, ensure_recording_table, register_recording


def has_learner_turns(db):
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='learner_turns'").fetchone() is not None


def backfill(database_path, store, limit):
    migrated = 0
    for _ in range(limit):
        with database_connection(database_path) as db:
            if not has_learner_turns(db):
                break
            row = db.execute('''SELECT session_id, turn_id, media_type, audio FROM learner_turns
                WHERE audio IS NOT NULL ORDER BY session_id, turn_id LIMIT 1''').fetchone()
        if row is None:
            break
        session_id, turn_id, media_type, audio = row
        recording = Recording.for_upload(session_id, turn_id, audio, media_type)
        store.put(recording, audio)
        store.read(recording)  # Verify remote bytes before clearing the original copy.
        with database_connection(database_path) as db:
            db.execute('BEGIN IMMEDIATE')
            current = db.execute('SELECT media_type, audio FROM learner_turns WHERE session_id=? AND turn_id=?',
                                 (session_id, turn_id)).fetchone()
            if current != (media_type, audio):
                continue
            store.verify(recording)
            ensure_recording_table(db)
            register_recording(db, session_id, turn_id, recording)
            db.execute('UPDATE learner_turns SET audio=NULL WHERE session_id=? AND turn_id=?', (session_id, turn_id))
        migrated += 1
    return migrated


def compact(database_path):
    with database_connection(database_path) as db:
        if has_learner_turns(db) and db.execute('SELECT 1 FROM learner_turns WHERE audio IS NOT NULL LIMIT 1').fetchone():
            raise sqlite3.OperationalError('Finish backfilling legacy recordings before compaction.')
        db.execute('VACUUM')
        if db.execute('PRAGMA quick_check').fetchall() != [('ok',)]:
            raise sqlite3.DatabaseError('Compacted database did not pass quick_check.')


def sweep(database_path, store, cutoff, *, apply=False):
    count = 0
    # Most old objects are referenced. Read the index once and recheck candidates under the write lock.
    with database_connection(database_path) as db:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='learner_recordings'").fetchone():
            raise sqlite3.OperationalError('Recording references have not been initialized in this database.')
        referenced = {row[0] for row in db.execute('SELECT object_key FROM learner_recordings')}
    for candidate in store.candidates(cutoff):
        if candidate.name in referenced:
            continue
        with database_connection(database_path) as db:
            db.execute('BEGIN IMMEDIATE')
            if not db.execute('SELECT 1 FROM learner_recordings WHERE object_key=?', (candidate.name,)).fetchone():
                count += store.delete_candidate(candidate) if apply else 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    backfill_command = commands.add_parser('backfill', help='Move one bounded batch of inline recordings')
    backfill_command.add_argument('--limit', type=int, default=25)
    commands.add_parser('compact', help='Rebuild SQLite after all inline recordings are migrated')
    sweep_command = commands.add_parser('sweep-orphans', help='Find unreferenced recording objects at least 24 hours old')
    sweep_command.add_argument('--apply', action='store_true', help='Delete eligible objects after rechecking references')
    args = parser.parse_args()
    settings = get_settings()
    if args.command == 'backfill':
        if args.limit < 1:
            parser.error('--limit must be positive')
        print(f'Migrated {backfill(settings.database_path, RecordingStore(settings), args.limit)} recordings.')
    elif args.command == 'compact':
        compact(settings.database_path)
        print('Compacted SQLite and verified integrity.')
    else:
        cutoff = datetime.now(timezone.utc) - timedelta(days=1)
        count = sweep(settings.database_path, RecordingStore(settings), cutoff, apply=args.apply)
        print(f'{"Removed" if args.apply else "Found"} {count} orphan objects.')


if __name__ == '__main__':
    main()

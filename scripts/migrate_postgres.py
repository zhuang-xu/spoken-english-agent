"""Initialize PostgreSQL or import a quiesced SQLite database with per-table verification."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))

import psycopg

from app.config import get_settings
from app.storage.database import database_connection
from app.storage.postgres import migrate
from app.storage.postgres_migration import import_sqlite

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('schema', 'import-sqlite'))
    args = parser.parse_args()
    settings = get_settings()
    url = settings.database_url.get_secret_value()
    if not url:
        parser.error('DATABASE_URL must contain the PostgreSQL migration connection.')
    if args.command == 'import-sqlite' and settings.database_path.startswith(('postgresql://', 'postgres://')):
        parser.error('DATABASE_PATH must point to the SQLite source.')
    try:
        with psycopg.connect(url, connect_timeout=10, autocommit=True) as target:
            migrate(target)
            if args.command == 'import-sqlite':
                with database_connection(settings.database_path) as source:
                    source.execute('BEGIN')
                    counts = import_sqlite(source, target)
                print(json.dumps(counts, sort_keys=True))
    except psycopg.Error as error:
        parser.exit(1, f'PostgreSQL migration failed ({error.sqlstate or "connection error"}).\n')


if __name__ == '__main__':
    main()

"""Read-only comparison; execute with Python inside the analytics image."""
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

import psycopg
from psycopg import sql

from etl.job import STREAMS
from etl.snapshots import SPECS

VARIABLES = {
    'moderation-service': 'MODERATION',
    'discord-dms-service': 'DISCORD',
    'player-service': 'PLAYER',
    'server-moderation-session-service': 'SESSION',
    'applicant-service': 'APPLICANT',
    'credential-service': 'CREDENTIAL',
    'server-rules-service': 'RULES',
    'university-record-service': 'RECORD',
}
FORBIDDEN = {
    'player-service': ('players', 'password_hash'),
    'applicant-service': ('applicants', 'deception'),
    'credential-service': ('credentials', 'university_email'),
    'discord-dms-service': ('messages', 'content'),
    'server-moderation-session-service': ('sessions', 'idempotency_key'),
}


def canonical(value):
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).isoformat()
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


def signatures(rows):
    # Intended for lab-sized data. No row values or hashes are printed.
    return sorted(hashlib.sha256(json.dumps(
        [canonical(value) for value in row], separators=(',', ':')
    ).encode()).hexdigest() for row in rows)


def main():
    results = []
    with psycopg.connect(os.environ['WAREHOUSE_DSN'], connect_timeout=10) as warehouse:
        warehouse.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
        for service, specs in {**STREAMS, **SPECS}.items():
            prefix = VARIABLES[service]
            with psycopg.connect(os.environ[prefix + '_DSN'], connect_timeout=10) as source:
                source.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
                source.execute("SELECT set_config('TimeZone',%s,true)",
                               (os.getenv(prefix + '_TIMEZONE', 'UTC'),))
                extra = [('decision_violations', 'bridge_decision_violations',
                          'decision_id rule_id', 'decision_id rule_id')] if service == 'moderation-service' else []
                for stream, target, fields, columns in [*specs, *extra]:
                    expressions = sql.SQL(',').join(
                        sql.SQL('{}::timestamptz').format(sql.Identifier(field))
                        if field in ('created_at', 'updated_at') else sql.Identifier(field)
                        for field in fields.split())
                    rows = source.execute(sql.SQL('SELECT {} FROM public.{}').format(
                        expressions, sql.Identifier(stream))).fetchall()
                    target_rows = warehouse.execute(sql.SQL('SELECT {} FROM analytics.{}').format(
                        sql.SQL(',').join(map(sql.Identifier, columns.split())),
                        sql.Identifier(target))).fetchall()
                    match = signatures(rows) == signatures(target_rows)
                    writable = source.execute(
                        "SELECT has_table_privilege(current_user,%s,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')",
                        ('public.' + stream,)).fetchone()[0]
                    if writable or not match:
                        print(f'{service}/{stream}: comparison or permission check failed', file=sys.stderr)
                        return 1
                    results.append({'source': service, 'table': stream, 'rows': len(rows),
                                    'data_matches': match, 'source_write_access': writable})
                if service in FORBIDDEN:
                    if source.execute("SELECT has_column_privilege(current_user,%s,%s,'SELECT')",
                                      FORBIDDEN[service]).fetchone()[0]:
                        print(f'{service}: excluded column is readable', file=sys.stderr)
                        return 1
        freshness = warehouse.execute('SELECT source_service,stream_name,latest_run_status '
                                      'FROM etl.source_freshness ORDER BY 1,2').fetchall()
        if len(freshness) != 10 or any(row[2] != 'succeeded' for row in freshness):
            print('Freshness check failed: expected ten successful streams', file=sys.stderr)
            return 1
        print(json.dumps({'tables': results, 'streams': freshness, 'verification': 'PASS'}, indent=2))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        # Raw database diagnostics can contain connection details or source values.
        print(f'Verification failed ({type(exc).__name__}); check configuration and source availability', file=sys.stderr)
        sys.exit(1)

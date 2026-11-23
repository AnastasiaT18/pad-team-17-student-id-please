#!/bin/sh
# May be sourced by the official image; keep shell options local to a subshell.
(
  set -eu
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -v ON_ERROR_STOP=1 \
    --set=replication_password="$REPLICATION_PASSWORD" <<'SQL'
SELECT 'CREATE ROLE replicator WITH REPLICATION LOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec
SELECT format('ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'replication_password') \gexec
SQL
  printf '\nhost replication replicator all scram-sha-256\n' >> "$PGDATA/pg_hba.conf"
)

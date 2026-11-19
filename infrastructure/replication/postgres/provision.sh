#!/bin/sh
# Prepare an existing primary via TCP; never initialize or overwrite its data directory.
set -eu
export PGPASSWORD="$POSTGRES_PASSWORD"
psql -h "$NODE_NAME" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -v ON_ERROR_STOP=1 \
  --set=replication_password="$REPLICATION_PASSWORD" <<'SQL'
SELECT 'CREATE ROLE replicator WITH REPLICATION LOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec
SELECT format('ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'replication_password') \gexec
SQL

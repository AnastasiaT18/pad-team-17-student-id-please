#!/bin/sh
set -eu
# The initdb temporary server only uses Unix sockets; TCP avoids reporting ready too early.
export PGPASSWORD="$POSTGRES_PASSWORD"
exec psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -Atqc 'SELECT 1'

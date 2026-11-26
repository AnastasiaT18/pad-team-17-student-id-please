#!/bin/sh
set -eu
umask 077

fence=/var/lib/postgresql/FENCED
if [ -f "$fence" ] && [ "${RESEED_NODE:-0}" != 1 ]; then
  echo 'Node is fenced. Use the CPR cluster.sh rejoin command; do not remove the marker manually.' >&2
  exit 1
fi

# Password stays outside primary_conninfo and is never printed. Escape pgpass metacharacters.
escaped=$(printf '%s' "$REPLICATION_PASSWORD" | sed 's/\\/\\\\/g; s/:/\\:/g')
printf '*:*:*:replicator:%s\n' "$escaped" > /var/lib/postgresql/.pgpass
chown postgres:postgres /var/lib/postgresql/.pgpass
chmod 600 /var/lib/postgresql/.pgpass
export PGPASSFILE=/var/lib/postgresql/.pgpass
# PostgreSQL 18 uses a versioned parent directory. Create it for the postgres user
# before the official entrypoint drops root privileges (our umask is restrictive).
mkdir -p "$(dirname "$PGDATA")"
chown postgres:postgres "$(dirname "$PGDATA")"
chmod 700 "$(dirname "$PGDATA")"

if [ "${RESEED_NODE:-0}" = 1 ]; then
  [ -f "$fence" ] || { echo 'Refusing to reseed an unfenced node.' >&2; exit 1; }
  if [ -d "$PGDATA" ]; then
    # Preserve the previous timeline for inspection/recovery; never erase it automatically.
    mv "$PGDATA" "$PGDATA.before-reseed-$(date +%Y%m%d%H%M%S)-$$"
  fi
fi

if [ ! -s "$PGDATA/PG_VERSION" ] && { [ "$NODE_MODE" = standby ] || [ "${RESEED_NODE:-0}" = 1 ]; }; then
  : "${REPLICATION_UPSTREAM:?A base backup requires an upstream primary}"
  mkdir -p "$(dirname "$PGDATA")"
  stage=$(mktemp -d "$PGDATA.bootstrap.XXXXXX")
  chown postgres:postgres "$stage"
  gosu postgres pg_basebackup \
    --dbname="host=$REPLICATION_UPSTREAM port=5432 user=replicator passfile=$PGPASSFILE application_name=$NODE_NAME connect_timeout=5" \
    --pgdata="$stage" --write-recovery-conf --wal-method=stream --checkpoint=fast --no-password
  # A partial backup never becomes the node's active data directory.
  # Some base images pre-create an empty PGDATA. Refuse to replace nonempty data.
  if [ -d "$PGDATA" ]; then rmdir "$PGDATA"; fi
  mv "$stage" "$PGDATA"
fi

if [ "${RESEED_NODE:-0}" = 1 ]; then
  rm "$fence"
  echo 'Fresh standby backup prepared; previous data directory preserved.'
  exit 0
fi

exec /usr/local/bin/docker-entrypoint.sh postgres "$@"

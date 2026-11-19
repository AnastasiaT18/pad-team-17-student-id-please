#!/usr/bin/env bash
# CPR manual database operations. Bash 3.2+, jq, Docker Compose; no private checkout/build.
set -eo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CLUSTER=${1:-}; [[ $# == 0 ]] || shift
case "$CLUSTER" in
  rules) INITIAL_PRIMARY=server-rules-db; APP=server-rules-service; VOLUME=server-rules-db-data; DSN_KEY=RULES_DSN ;;
  record) INITIAL_PRIMARY=university-record-db; APP=university-record-service; VOLUME=university-record-db-data; DSN_KEY=RECORD_DSN ;;
  *) echo 'Usage: bash infrastructure/replication/cluster.sh {rules|record} COMMAND' >&2; exit 1 ;;
esac
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
COMPOSE=(docker compose --project-directory "$ROOT")
[[ -z "${CPR_HA_ENV_FILE:-}" ]] || COMPOSE+=(--env-file "$CPR_HA_ENV_FILE")
[[ -z "${CPR_HA_PROJECT:-}" ]] || COMPOSE+=(--project-name "$CPR_HA_PROJECT")
COMPOSE+=(-f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.replication.yml")
# Never print resolved config: it contains credentials. Extract only the project name.
PROJECT=$("${COMPOSE[@]}" config --format json | jq -r '.name')
[[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'Invalid project name' >&2; exit 1; }
NODES=("$INITIAL_PRIMARY" "$INITIAL_PRIMARY-standby-1" "$INITIAL_PRIMARY-standby-2")
die() { echo "ERROR: $*" >&2; exit 1; }
node() { local n; for n in "${NODES[@]}"; do [[ "$1" != "$n" ]] || return 0; done; die "Unknown node: $1"; }

# Bound commands without requiring GNU timeout (not installed by default on macOS).
dc() {
  local pid start=$SECONDS limit=${HA_COMMAND_TIMEOUT:-180} code=0
  "${COMPOSE[@]}" "$@" <&0 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS - start >= limit )); then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo 'Docker command timed out; inspect status before retrying.' >&2
      return 124
    fi
    sleep 0.1
  done
  wait "$pid" || code=$?
  return "$code"
}

sql() {
  node "$1"
  HA_COMMAND_TIMEOUT=15 dc exec -T "$1" sh -c \
    'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -v ON_ERROR_STOP=1 -A -t -F "|"'
}
query() { printf '%s\n' "$2" | sql "$1"; }
state() {
  query "$1" "SELECT pg_is_in_recovery(), COALESCE(pg_last_wal_receive_lsn(), '0/0'), COALESCE(pg_last_wal_replay_lsn(), '0/0'), system_identifier FROM pg_control_system();" 2>/dev/null
}
primary() {
  local n s found='' count=0
  for n in "${NODES[@]}"; do
    s=$(state "$n") || continue
    if [[ "$s" == f\|* ]]; then found=$n; count=$((count + 1)); fi
  done
  [[ $count == 1 ]] || die "Expected exactly one reachable primary; found $count. Run status."
  printf '%s\n' "$found"
}
inspect() {
  local id
  id=$(dc ps -a -q "$1")
  [[ -n "$id" && "$id" != *$'\n'* ]] || die "Expected one container for $1"
  docker inspect --format '{{.State.Running}}|{{.State.ExitCode}}|{{.HostConfig.RestartPolicy.Name}}' "$id"
}
fence() {
  local id running exitcode restart
  id=$(dc ps -a -q "$1")
  [[ -n "$id" && "$id" != *$'\n'* ]] || die "Cannot establish fencing for $1"
  dc stop --timeout 15 "$1"
  IFS='|' read -r running exitcode restart <<< "$(inspect "$1")"
  [[ "$running" == false && ( "$restart" == no || -z "$restart" ) ]] || die 'Fencing failed: node must be stopped with restart disabled'
  dc run --rm --no-deps --entrypoint /bin/sh "$1" -c 'touch /var/lib/postgresql/FENCED'
  echo "Fenced $1: stopped and persistent startup guard installed."
}
wait_query() {
  local n=$1 statement=$2 expected=$3 limit=${4:-60} start=$SECONDS result
  while (( SECONDS - start < limit )); do
    result=$(query "$n" "$statement" 2>/dev/null) || result=''
    [[ "$result" == "$expected" ]] && return 0
    sleep 1
  done
  die "Timed out waiting for $n: $statement"
}
lsn_key() {
  [[ "$1" =~ ^[0-9A-Fa-f]+/[0-9A-Fa-f]+$ ]] || die 'Invalid WAL position'
  # Compare normalized hex strings, avoiding signed 64-bit arithmetic overflow.
  printf '%08X%08X' "0x${1%/*}" "0x${1#*/}"
}
failover() {
  local old=$1 requested=${2:-} n s old_system='' recovery received replay system key
  local available=() best='' chosen='' best_key='' candidate_key=''
  node "$old"
  [[ -z "$requested" ]] || node "$requested"
  analytics_ready
  for n in "${NODES[@]}"; do
    s=$(state "$n") || continue
    IFS='|' read -r recovery received replay system <<< "$s"
    if [[ "$n" == "$old" ]]; then
      [[ "$recovery" == f ]] || die "$old is a standby, not the primary to fence"
      old_system=$system
    elif [[ "$recovery" == f ]]; then
      die 'Another primary is reachable; refusing a second promotion.'
    fi
  done
  dc run --rm --no-deps --entrypoint /bin/sh "$old" -c \
    'test -s "$PGDATA/PG_VERSION" && test ! -f "$PGDATA/standby.signal"' || die 'Named old primary has no initialized primary data directory'
  fence "$old"
  local cluster_system=$old_system
  for n in "${NODES[@]}"; do
    [[ "$n" != "$old" ]] || continue
    s=$(state "$n") || continue
    [[ "$s" == t\|* ]] || die 'Node role changed during failover; inspect status.'
    wait_query "$n" 'SELECT NOT pg_is_wal_replay_paused() AND pg_last_wal_replay_lsn() >= pg_last_wal_receive_lsn();' t 30
    s=$(state "$n") || die "Standby $n became unavailable"
    IFS='|' read -r recovery received replay system <<< "$s"
    [[ "$recovery" == t ]] || die 'Standby role changed during failover'
    [[ -z "$cluster_system" || "$system" == "$cluster_system" ]] || die 'Database system identifiers differ'
    cluster_system=$system
    key=$(lsn_key "$replay")
    available+=("$n")
    if [[ -z "$best" || "$key" > "$best_key" ]]; then best=$n; best_key=$key; fi
    [[ "$n" != "$requested" ]] || candidate_key=$key
  done
  [[ -n "$best" ]] || die 'No available standby; old primary remains fenced.'
  chosen=$best
  if [[ -n "$requested" ]]; then
    [[ -n "$candidate_key" && "$candidate_key" == "$best_key" ]] || die 'Requested candidate is unavailable or behind another standby'
    chosen=$requested
  fi
  echo "Promoting $chosen; asynchronous replication can lose WAL not received by available standbys."
  [[ "$(query "$chosen" 'SELECT pg_promote(true, 30);')" == t ]] || die 'Promotion did not complete; inspect status before retrying'
  # Rotate the replicated version after promotion: old Redis keys become unreachable
  # without flushing authentication entries or any other service's cache.
  if [[ "$CLUSTER" == rules && "$(query "$chosen" "SELECT to_regclass('public.rules_revision') IS NOT NULL;")" == t ]]; then
    query "$chosen" 'UPDATE rules_revision SET revision = gen_random_uuid()::text WHERE id = 1;'
  fi
  echo "New primary: $chosen. JDBC connections can now select it."
  for n in "${available[@]}"; do
    [[ "$n" != "$chosen" ]] || continue
    query "$n" "ALTER SYSTEM SET primary_conninfo = 'host=$chosen port=5432 user=replicator passfile=/var/lib/postgresql/.pgpass application_name=$n connect_timeout=5'; SELECT pg_reload_conf();"
    echo "Repointed $n; inspect status or rejoin if it cannot follow WAL history."
  done
  echo "Rebuild the former primary: bash infrastructure/replication/cluster.sh $CLUSTER rejoin $old"
}
rejoin() {
  local upstream
  node "$1"
  upstream=$(primary)
  [[ "$1" != "$upstream" ]] || die 'Refusing to rebuild the current primary'
  fence "$1"
  dc run --rm --no-deps -e RESEED_NODE=1 -e "REPLICATION_UPSTREAM=$upstream" "$1"
  dc up -d --no-deps "$1"
  wait_query "$1" 'SELECT pg_is_in_recovery();' t
  wait_query "$1" 'SELECT status FROM pg_stat_wal_receiver;' streaming
  echo "$1 is a standby of $upstream; prior data directory preserved."
}
status() {
  local n s recovery received replay system
  for n in "${NODES[@]}"; do
    s=$(state "$n") || { echo "$n: stopped, fenced, or unavailable"; continue; }
    IFS='|' read -r recovery received replay system <<< "$s"
    if [[ "$recovery" == t ]]; then
      echo "$n: standby receive=$received replay=$replay $(query "$n" "SELECT status || ' from ' || sender_host FROM pg_stat_wal_receiver;")"
    else
      echo "$n: PRIMARY"
      query "$n" 'SELECT application_name, state, sync_state, replay_lsn FROM pg_stat_replication ORDER BY application_name;'
    fi
  done
}

analytics_ready() {
  local dsn scheduler live
  dsn=$(dc config --format json | jq -r --arg k "$DSN_KEY" '.services["analytics-scheduler"].environment[$k]')
  [[ "$dsn" == *"$INITIAL_PRIMARY-standby-1"* && "$dsn" == *"$INITIAL_PRIMARY-standby-2"* && "$dsn" == *target_session_attrs=read-write* ]] || die "Update the analytics HA DSN for $CLUSTER using .env.example first"
  scheduler=$(dc ps -q analytics-scheduler)
  if [[ -n "$scheduler" ]]; then
    live=$(docker inspect "$scheduler" | jq -r --arg k "$DSN_KEY" '.[0].Config.Env[] | select(startswith($k + "="))')
    [[ "$live" == "$DSN_KEY=$dsn" ]] || die 'Recreate analytics-scheduler with the updated DSN before enabling/failing over'
  fi
}

prepare() {
  local version backup volume system
  [[ "$(primary)" == "$INITIAL_PRIMARY" ]] || die 'Prepare requires the original primary to be running'
  version=$(query "$INITIAL_PRIMARY" 'SHOW server_version_num;')
  [[ "$version" == 18* ]] || die 'Existing database must be PostgreSQL 18'
  [[ "$(query "$INITIAL_PRIMARY" 'SHOW data_directory;')" == /var/lib/postgresql/18/docker ]] || die 'Unexpected PGDATA; use a separate migration plan'
  system=$(query "$INITIAL_PRIMARY" 'SELECT system_identifier FROM pg_control_system();')
  volume=$(dc config --format json | jq -r --arg v "$VOLUME" '.volumes[$v].name')
  backup="$ROOT/infrastructure/backups/$PROJECT-$CLUSTER-$(date +%Y%m%d%H%M%S)-$$"
  (umask 077; mkdir -p "$backup")
  dc exec -T "$INITIAL_PRIMARY" sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$backup/database.dump.partial"
  dc exec -T "$INITIAL_PRIMARY" pg_restore --list < "$backup/database.dump.partial" > /dev/null
  mv "$backup/database.dump.partial" "$backup/database.dump"
  dc exec -T "$INITIAL_PRIMARY" sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec pg_dumpall -U "$POSTGRES_USER" --roles-only' > "$backup/roles.sql"
  chmod 600 "$backup/database.dump" "$backup/roles.sql"
  # Override entrypoint: open only a network SQL connection, without booting another postgres.
  dc run --rm --no-deps --entrypoint sh "$INITIAL_PRIMARY" /opt/pad17-ha/provision.sh
  dc exec -T "$INITIAL_PRIMARY" sh -c 'line="host replication replicator all scram-sha-256"; grep -Fqx "$line" "$PGDATA/pg_hba.conf" || printf "\n%s\n" "$line" >> "$PGDATA/pg_hba.conf"'
  query "$INITIAL_PRIMARY" 'SELECT pg_reload_conf();'
  printf '%s\n%s\n%s\n' "$volume" "$system" "$backup" > "$ROOT/.replication-state/$PROJECT-$CLUSTER.prepared"
  echo "Backup archive readable; original volume retained. Prepared backup: $backup"
}

enable() {
  local n s volume receipt control expected backup
  analytics_ready
  for n in "${NODES[@]}"; do
    s=$(state "$n") || continue
    [[ "$s" != f\|* || "$n" == "$INITIAL_PRIMARY" ]] || die 'Cluster already failed over; use the documented restart procedure'
  done
  volume=$(dc config --format json | jq -r --arg v "$VOLUME" '.volumes[$v].name')
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    receipt="$ROOT/.replication-state/$PROJECT-$CLUSTER.prepared"
    [[ -f "$receipt" && "$(sed -n '1p' "$receipt")" == "$volume" ]] || die 'Existing volume detected. Run prepare and retain its backup before enabling.'
    backup=$(sed -n '3p' "$receipt")
    [[ -s "$backup/database.dump" && -s "$backup/roles.sql" ]] || die 'Prepared backup files are missing'
    dc run --rm --no-deps --entrypoint sh "$INITIAL_PRIMARY" -c 'test ! -f /var/lib/postgresql/FENCED && test ! -f "$PGDATA/standby.signal"' || die 'Original primary is fenced or rebuilt as a standby'
    expected=$(sed -n '2p' "$receipt")
    control=$(dc run --rm --no-deps --entrypoint sh "$INITIAL_PRIMARY" -c 'LC_ALL=C pg_controldata "$PGDATA"' | sed -n 's/^Database system identifier: *//p')
    [[ -n "$expected" && "$control" == "$expected" ]] || die 'Primary volume differs from the prepared database'
  fi
  # This is an explicit deployment operation. Expect a short outage for this service.
  dc stop "$APP"
  dc up -d --no-deps --wait "$INITIAL_PRIMARY"
  dc up -d --no-deps --wait "${NODES[1]}" "${NODES[2]}"
  dc up -d --no-deps "$APP"
  echo 'Enabled. Check both application replicas in Discovery before sending traffic.'
}

# Atomic mkdir works on macOS and Linux without a flock executable. The verify command
# holds the lock across Maven; its child commands inherit a checked ownership token.
LOCK="$ROOT/.replication-state/$PROJECT-$CLUSTER.lock.d"
mkdir -p "$ROOT/.replication-state"
if [[ -n "${HA_LOCK_TOKEN:-}" && -f "$LOCK/owner" && -f "$LOCK/token" && "$(cat "$LOCK/token")" == "$HA_LOCK_TOKEN" ]] && kill -0 "$(cat "$LOCK/owner")" 2>/dev/null; then
  : # Child operation inside this operator's verification run.
else
  mkdir "$LOCK" 2>/dev/null || die "Another operation holds $LOCK; inspect its owner before removing a stale lock."
  export HA_LOCK_TOKEN="$$-$RANDOM-$RANDOM"
  printf '%s\n' "$$" > "$LOCK/owner"
  printf '%s\n' "$HA_LOCK_TOKEN" > "$LOCK/token"
  trap 'rm -f "$LOCK/owner" "$LOCK/token"; rmdir "$LOCK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi
command=${1:-}; [[ $# == 0 ]] || shift
case "$command" in
  prepare) [[ $# == 0 ]] || die 'Usage: cluster.sh {rules|record} prepare'; prepare ;;
  enable) [[ $# == 0 ]] || die 'Usage: cluster.sh {rules|record} enable'; enable ;;
  status) [[ $# == 0 ]] || die 'Usage: cluster.sh status'; status ;;
  stop) [[ $# == 0 ]] || die 'Usage: cluster.sh stop'; dc stop "$APP" "${NODES[@]}" ;;
  failover)
    [[ $# == 1 || ( $# == 3 && "$2" == --candidate ) ]] || die 'Usage: cluster.sh failover OLD_PRIMARY [--candidate NODE]'
    failover "$1" "${3:-}" ;;
  rejoin) [[ $# == 1 ]] || die 'Usage: cluster.sh rejoin NODE'; rejoin "$1" ;;
  # Machine-readable operations used by the existing Java test infrastructure.
  sql) [[ $# == 1 ]] || die 'Usage: cluster.sh sql NODE < query.sql'; sql "$1" ;;
  state) [[ $# == 1 ]] || die 'Usage: cluster.sh state NODE'; node "$1"; state "$1" ;;
  primary) [[ $# == 0 ]] || die 'Usage: cluster.sh primary'; primary ;;
  inspect) [[ $# == 1 ]] || die 'Usage: cluster.sh inspect NODE'; node "$1"; inspect "$1" ;;
  compose) dc "$@" ;;
  *) die 'Usage: bash infrastructure/replication/cluster.sh {rules|record} {prepare|enable|status|failover|rejoin|stop}' ;;
esac

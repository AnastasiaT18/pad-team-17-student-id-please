#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
pair=${1:?Usage: database-replication.sh moderation|discord-dms prepare|up|status|failover|complete|rejoin|stop}
case "$pair" in moderation|discord-dms) ;; *) echo 'Unknown private service' >&2; exit 2;; esac
shift
export COMPOSE_PROJECT_NAME=${CPR_PROJECT_NAME:-pad-team-17}
[[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]+$ ]] || exit 2
export REPLICATION_STATE_ROOT="$PWD/.replication/$COMPOSE_PROJECT_NAME"
REPLICATION_STATE_DIR="$REPLICATION_STATE_ROOT/$pair"
envfile=${CPR_ENV_FILE:-.env}
basefile=${CPR_COMPOSE_BASE_FILE:-docker-compose.yml}
compose() { docker compose --env-file "$envfile" -f "$basefile" -f docker-compose.replication.yml -p "$COMPOSE_PROJECT_NAME" "$@"; }
fail() { echo "$*" >&2; exit 1; }
node_name() { case "$1" in db-1|db-2|db-3) ;; *) fail 'Node must be db-1, db-2 or db-3';; esac; }
sql() { compose exec -T "$pair-$1" sh -c 'exec psql -X -v ON_ERROR_STOP=1 -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<< "$2"; }
wait_sql() {
  local node=$1 query=$2 expected=$3 value i
  for ((i=0;i<60;i++)); do
    value=$(sql "$node" "$query" 2>/dev/null) || value=''
    [ "$value" != "$expected" ] || return 0
    sleep 1
  done
  fail "Timed out waiting for $node"
}
metadata() {
  sql "$1" "SELECT system_identifier FROM pg_control_system(); SELECT timeline_id FROM pg_control_checkpoint(); SELECT COALESCE(encode(pg_read_binary_file('pg_wal/' || upper(lpad(to_hex(timeline_id),8,'0')) || '.history',0,100000,true),'hex'),'root') FROM pg_control_checkpoint();"
}
route() {
  local node=$1
  node_name "$node"
  cat > "$REPLICATION_STATE_DIR/haproxy.cfg.tmp" <<CONFIG
global
  log stdout format raw local0
defaults
  mode tcp
  timeout connect 3s
  timeout client 1h
  timeout server 1h
resolvers docker
  nameserver dns 127.0.0.11:53
  resolve_retries 3
  timeout resolve 1s
  timeout retry 1s
  hold valid 5s
frontend postgres
  bind :5432
  default_backend writer
backend writer
  server primary $node:5432 check inter 1s fall 2 rise 1 resolvers docker init-addr libc,none on-marked-down shutdown-sessions
CONFIG
  mv "$REPLICATION_STATE_DIR/haproxy.cfg.tmp" "$REPLICATION_STATE_DIR/haproxy.cfg"
  printf '%s\n' "$node" > "$REPLICATION_STATE_DIR/primary.tmp"
  mv "$REPLICATION_STATE_DIR/primary.tmp" "$REPLICATION_STATE_DIR/primary"
}
fence() {
  local node=$1 cid
  cid=$(compose ps -a -q "$pair-$node")
  [ -n "$cid" ] || fail "Missing container for $node; refusing promotion"
  # Marker also protects against an explicit docker start or compose recreation.
  compose run --rm --no-deps --entrypoint sh "$pair-$node" -c 'touch /var/lib/postgresql/data/FENCED' >/dev/null
  docker update --restart=no "$cid" >/dev/null
  docker stop -t 20 "$cid" >/dev/null
  [ "$(docker inspect -f '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' "$cid")" = 'false no' ] || fail 'Fencing could not be verified'
}
rebuild() {
  local node=$1 primary=$2
  fence "$node"
  compose run --rm --no-deps --entrypoint /usr/local/bin/rebuild.sh "$pair-$node" "$primary"
  compose start "$pair-$node"
  if ! (wait_sql "$node" 'SELECT pg_is_in_recovery()' t); then
    fence "$node"; fail "Rejoin failed for $node; fence restored"
  fi
  # Same cluster and a live receiver attached to the current primary are required.
  [ "$(sql "$node" 'SELECT system_identifier FROM pg_control_system()')" = "$(head -1 "$REPLICATION_STATE_DIR/identity")" ] || { fence "$node"; fail 'Rebuilt cluster identifier mismatch'; }
  if ! (wait_sql "$node" "SELECT count(*) FROM pg_stat_wal_receiver WHERE status='streaming' AND sender_host='$primary'" 1); then
    fence "$node"; fail "Replication did not resume for $node"
  fi
  echo "$node rejoined $primary as a standby"
}
complete_promotion() {
    [ -f "$REPLICATION_STATE_DIR/pending" ] || fail 'No pending promotion'
    old=$(sed -n '1p' "$REPLICATION_STATE_DIR/pending")
    best=$(sed -n '2p' "$REPLICATION_STATE_DIR/pending")
    node_name "$old"; node_name "$best"
    fence "$old"
    [ "$(sql "$best" 'SELECT system_identifier FROM pg_control_system()')" = "$(head -1 "$REPLICATION_STATE_DIR/identity")" ] || fail 'Promoted cluster identifier mismatch'
    if [ "$(sql "$best" 'SELECT pg_is_in_recovery()')" = t ]; then
      metadata "$best" > "$REPLICATION_STATE_DIR/candidate"
      cmp -s "$REPLICATION_STATE_DIR/identity" "$REPLICATION_STATE_DIR/candidate" || fail 'Pending candidate history changed'
      [ "$(sql "$best" 'SELECT pg_promote(true, 60)')" = t ] || fail 'Pending promotion failed'
    fi
    wait_sql "$best" 'SELECT pg_is_in_recovery()' f
    sql "$best" 'CHECKPOINT' >/dev/null
    metadata "$best" > "$REPLICATION_STATE_DIR/identity.tmp"
    route "$best"
    compose up -d --no-deps "$pair-db-router"
    compose restart "$pair-db-router"
    mv "$REPLICATION_STATE_DIR/identity.tmp" "$REPLICATION_STATE_DIR/identity"
    rm "$REPLICATION_STATE_DIR/pending"
    echo "Promoted $best; application connections now route there. Rejoin the other nodes explicitly."
}
if [ -d "$REPLICATION_STATE_ROOT/cutover-lock" ] && [ "${CPR_CUTOVER_IN_PROGRESS:-0}" != 1 ]; then
  fail 'A cutover operation is in progress'
fi
mkdir -p "$REPLICATION_STATE_DIR"
# Single host lock shared by all commands for this project. Never break it automatically.
mkdir "$REPLICATION_STATE_DIR/lock" 2>/dev/null || fail 'Another operation or an interrupted command holds the lock; inspect before removing it'
trap 'rmdir "$REPLICATION_STATE_DIR/lock"' EXIT
command=${1:-status}
case "$command" in
  up|prepare)
    [ ! -f "$REPLICATION_STATE_DIR/pending" ] || fail 'Complete the pending failover first'
    if [ ! -f "$REPLICATION_STATE_DIR/primary" ]; then
      # Never infer an initial primary from existing database volumes.
      for number in 1 2 3; do
        [ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" --filter "label=com.docker.compose.volume=$pair-replica-$number")" ] || fail 'Replica volumes exist without routing state; recover the state before starting'
      done
      route db-1
    fi
    if [ "${REPLICATION_SKIP_PULL:-0}" != 1 ]; then
      compose pull "$pair-db-1" "$pair-db-migrate" "$pair-db-router"
    fi
    primary=$(cat "$REPLICATION_STATE_DIR/primary")
    node_name "$primary"
    compose up -d --no-deps "$pair-$primary"
    wait_sql "$primary" 'SELECT pg_is_in_recovery()' f
    metadata "$primary" > "$REPLICATION_STATE_DIR/identity.tmp"
    if [ -f "$REPLICATION_STATE_DIR/identity" ]; then
      cmp -s "$REPLICATION_STATE_DIR/identity" "$REPLICATION_STATE_DIR/identity.tmp" || fail 'Primary identity changed unexpectedly'
    fi
    mv "$REPLICATION_STATE_DIR/identity.tmp" "$REPLICATION_STATE_DIR/identity"
    [ "$command" != prepare ] || exit 0
    [ -f "$REPLICATION_STATE_DIR/restored" ] || fail 'Restore and verify the original database first; see the cutover script'
    compose up -d --no-deps "$pair-db-1" "$pair-db-2" "$pair-db-3" "$pair-db-router"
    for node in db-1 db-2 db-3; do
      [ "$node" = "$primary" ] || wait_sql "$node" 'SELECT pg_is_in_recovery()' t
    done
    compose run --rm --no-deps "$pair-db-migrate"
    ;;
  failover)
    [ -f "$REPLICATION_STATE_DIR/identity" ] || fail 'Initialize the cluster first'
    old=$(cat "$REPLICATION_STATE_DIR/primary")
    node_name "$old"
    [ ! -f "$REPLICATION_STATE_DIR/pending" ] || fail 'A promotion is pending; use complete to finish routing it'
    requested=${2:-}
    [ -z "$requested" ] || node_name "$requested"
    [ "$requested" != "$old" ] || fail 'The current primary cannot be its own failover candidate'
    fence "$old"
    rm -f "$REPLICATION_STATE_DIR"/db-*.lsn
    best='' best_lsn='0/0'
    for node in db-1 db-2 db-3; do
      [ "$node" != "$old" ] || continue
      recovery=$(sql "$node" 'SELECT pg_is_in_recovery()' 2>/dev/null) || { echo "$node unavailable; its WAL cannot be compared" >&2; continue; }
      [ "$recovery" = t ] || fail "$node is writable unexpectedly; refusing split-brain promotion"
      # Wait until the old primary's stream has closed before comparing durable WAL.
      wait_sql "$node" 'SELECT count(*) FROM pg_stat_wal_receiver' 0
      metadata "$node" > "$REPLICATION_STATE_DIR/candidate"
      cmp -s "$REPLICATION_STATE_DIR/identity" "$REPLICATION_STATE_DIR/candidate" || fail "$node has an incompatible or unconfirmed cluster/timeline history"
      lsn=$(sql "$node" "SELECT COALESCE(pg_last_wal_receive_lsn()::text, '')")
      [[ "$lsn" =~ ^[0-9A-F]+/[0-9A-F]+$ ]] || fail "$node has no durable streaming WAL position"
      # The old primary is stopped. Capture received WAL and wait for it to replay.
      wait_sql "$node" "SELECT pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn" t
      if [ -z "$best" ] || [ "$(sql "$node" "SELECT '$lsn'::pg_lsn > '$best_lsn'::pg_lsn")" = t ]; then
        best=$node; best_lsn=$lsn
      fi
      printf '%s\n' "$lsn" > "$REPLICATION_STATE_DIR/$node.lsn"
    done
    [ -n "$best" ] || fail 'No eligible standby is available'
    if [ -n "$requested" ]; then
      [ "$requested" != "$old" ] && [ -f "$REPLICATION_STATE_DIR/$requested.lsn" ] || fail 'Requested candidate is unavailable'
      requested_lsn=$(cat "$REPLICATION_STATE_DIR/$requested.lsn")
      [ "$(sql "$best" "SELECT '$requested_lsn'::pg_lsn >= '$best_lsn'::pg_lsn")" = t ] || fail 'Requested standby is behind another available standby'
      best=$requested
    fi
    printf '%s\n%s\n' "$old" "$best" > "$REPLICATION_STATE_DIR/pending.tmp"
    mv "$REPLICATION_STATE_DIR/pending.tmp" "$REPLICATION_STATE_DIR/pending"
    [ "$(sql "$best" 'SELECT pg_promote(true, 60)')" = t ] || fail 'Promotion did not finish; use complete after inspection'
    complete_promotion
    ;;
  complete)
    complete_promotion
    ;;
  rejoin)
    [ ! -f "$REPLICATION_STATE_DIR/pending" ] || fail 'Complete the pending promotion first'
    node=${2:?Specify the node to rebuild}; node_name "$node"
    [ "${3:-}" = --rebuild ] || fail 'Use rejoin db-N --rebuild to acknowledge replacing its active data directory; the previous directory is retained'
    primary=$(cat "$REPLICATION_STATE_DIR/primary")
    node_name "$primary"
    [ "$node" != "$primary" ] || fail 'Cannot rebuild the current primary'
    wait_sql "$primary" 'SELECT pg_is_in_recovery()' f
    metadata "$primary" > "$REPLICATION_STATE_DIR/candidate"
    cmp -s "$REPLICATION_STATE_DIR/identity" "$REPLICATION_STATE_DIR/candidate" || fail 'Current primary identity changed'
    rebuild "$node" "$primary"
    ;;
  verify)
    primary=$(cat "$REPLICATION_STATE_DIR/primary"); node_name "$primary"
    wait_sql "$primary" 'SELECT pg_is_in_recovery()' f
    metadata "$primary" > "$REPLICATION_STATE_DIR/candidate"
    cmp -s "$REPLICATION_STATE_DIR/identity" "$REPLICATION_STATE_DIR/candidate" || fail 'Primary identity differs from recorded state'
    lsn=$(sql "$primary" 'SELECT pg_current_wal_flush_lsn()')
    [[ "$lsn" =~ ^[0-9A-F]+/[0-9A-F]+$ ]] || fail 'Invalid primary WAL position'
    for node in db-1 db-2 db-3; do
      [ "$node" != "$primary" ] || continue
      wait_sql "$node" 'SELECT pg_is_in_recovery()' t
      wait_sql "$node" "SELECT count(*) FROM pg_stat_wal_receiver WHERE status='streaming' AND sender_host='$primary'" 1
      wait_sql "$node" "SELECT pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn" t
    done
    echo "$pair: writer identity and both streaming standbys verified"
    ;;
  status)
    compose ps -a "$pair-db-1" "$pair-db-2" "$pair-db-3" "$pair-db-router"
    for node in db-1 db-2 db-3; do
      printf '%s: ' "$node"
      sql "$node" "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END, pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()" || true
    done
    ;;
  stop) compose stop "$pair-db-router" "$pair-db-1" "$pair-db-2" "$pair-db-3" ;;
  *) fail 'Usage: database-replication.sh PAIR prepare|up|status|failover [db-N]|complete|rejoin db-N --rebuild|stop' ;;
esac

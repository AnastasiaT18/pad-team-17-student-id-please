#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
export COMPOSE_PROJECT_NAME=${CPR_PROJECT_NAME:-pad-team-17}
[[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9-]+$ ]] || exit 2
export REPLICATION_STATE_ROOT="$PWD/.replication/$COMPOSE_PROJECT_NAME"
envfile=${CPR_ENV_FILE:-.env}
basefile=${CPR_COMPOSE_BASE_FILE:-docker-compose.yml}
base() { docker compose --env-file "$envfile" -f "$basefile" -p "$COMPOSE_PROJECT_NAME" "$@"; }
replicated() { docker compose --env-file "$envfile" -f "$basefile" -f docker-compose.replication.yml -p "$COMPOSE_PROJECT_NAME" "$@"; }
fail() { echo "$*" >&2; exit 1; }
cutover_state=$REPLICATION_STATE_ROOT
case "${1:-}" in
  player)
    pairs=(player)
    legacy_databases=(player-db)
    apps=(player-service)
    cutover_state="$REPLICATION_STATE_ROOT/player"
    shift
    ;;
  session)
    pairs=(session)
    legacy_databases=(server-moderation-session-db)
    apps=(server-moderation-session-service)
    cutover_state="$REPLICATION_STATE_ROOT/session"
    shift
    ;;
  *)
    pairs=(moderation discord-dms)
    legacy_databases=(moderation-db discord-dms-db)
    apps=(moderation-service discord-dms-service)
    ;;
esac
paused_services=("${apps[@]}" analytics-scheduler analytics-etl)
etl_sources=()
for app in "${apps[@]}"; do
  etl_sources+=(--source "$app")
done

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}
source_sql() { base exec -T "$1" sh -c 'exec psql -XAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; }
target_sql() { replicated exec -T "$1-db-1" sh -c 'exec psql -XAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; }
assert_stopped() {
  local cid service ids
  for service in "$@"; do
    ids=$(base ps -a -q "$service") || fail "Could not check whether $service is stopped"
    for cid in $ids; do
      [ "$(docker inspect -f '{{.State.Running}}' "$cid")" = false ] || fail "$service is still running; keep writes paused"
    done
  done
}
compose_setting() {
  local settings=$1 key=$2 line
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done <<< "$settings"
  return 1
}

configure_analytics_routes() {
  local phase=$1 settings pair active_file legacy_key ha_key target_key key value scope
  settings=$(replicated config --environment) || fail 'Could not resolve Compose environment'
  for pair in moderation discord-dms player session; do
    case "$pair" in
      moderation)
        active_file="$REPLICATION_STATE_ROOT/activated"
        legacy_key=ANALYTICS_MODERATION_DSN
        ha_key=ANALYTICS_MODERATION_REPLICATION_DSN
        target_key=CPR_ANALYTICS_MODERATION_DSN
        ;;
      discord-dms)
        active_file="$REPLICATION_STATE_ROOT/activated"
        legacy_key=ANALYTICS_DISCORD_DSN
        ha_key=ANALYTICS_DISCORD_REPLICATION_DSN
        target_key=CPR_ANALYTICS_DISCORD_DSN
        ;;
      player|session)
        active_file="$REPLICATION_STATE_ROOT/$pair/activated"
        case "$pair" in player) scope=PLAYER ;; session) scope=SESSION ;; esac
        legacy_key=ANALYTICS_${scope}_DSN
        ha_key=ANALYTICS_${scope}_HA_DSN
        target_key=CPR_ANALYTICS_${scope}_DSN
        ;;
    esac
    if [ -f "$active_file" ] || { [ "$phase" = verify ] && [[ " ${pairs[*]} " == *" $pair "* ]]; }; then
      key=$ha_key
    else
      key=$legacy_key
    fi
    value=$(compose_setting "$settings" "$key") && [ -n "$value" ] || fail "Set $key before starting Analytics"
    export "$target_key=$value"
  done
}

mkdir -p "$REPLICATION_STATE_ROOT"
mkdir "$REPLICATION_STATE_ROOT/cutover-lock" 2>/dev/null || fail 'Another cutover or an interrupted command holds the lock'
trap 'rmdir "$REPLICATION_STATE_ROOT/cutover-lock"' EXIT
for pair in moderation discord-dms player session; do
  [ ! -d "$REPLICATION_STATE_ROOT/$pair/lock" ] || fail "$pair has an active or interrupted database operation"
done
export CPR_CUTOVER_IN_PROGRESS=1
mkdir -p "$cutover_state"
if [ "${1:-}" != resume-analytics ]; then
  [ ! -f "$cutover_state/rolled-back" ] || fail 'This cutover was rolled back; its snapshots are stale. Review and reset only the new replica volumes/state before a fresh cutover.'
fi
case "${1:-}" in
  backup)
    [ ! -f "$cutover_state/activated" ] || fail 'Already activated; a new backup of stale legacy databases is not a rollback plan'
    replicated config --quiet
    for i in "${!pairs[@]}"; do
      pair=${pairs[i]}
      source=${legacy_databases[i]}
      [ ! -f "$REPLICATION_STATE_ROOT/$pair/restored" ] || fail 'A restore is already recorded; inspect it instead of replacing the backup'
      [ "$(source_sql "$source" <<< "SELECT count(*) FROM pg_roles WHERE rolname='replicator'")" = 0 ] || fail 'Source already contains reserved replicator role; review before migration'
    done
    base stop "${paused_services[@]}"
    assert_stopped "${paused_services[@]}"
    backup="$PWD/.replication-backups/$COMPOSE_PROJECT_NAME/$(date -u +%Y%m%dT%H%M%SZ)-${pairs[0]}"
    mkdir -p "$(dirname "$backup")"
    mkdir "$backup"
    for i in "${!pairs[@]}"; do
      pair=${pairs[i]}
      source=${legacy_databases[i]}
      mkdir "$backup/$pair"
      source_sql "$source" < scripts/replication/export-roles.sql > "$backup/$pair/roles.sql"
      source_sql "$source" < scripts/replication/fingerprints.sql > "$backup/$pair/source.fingerprints"
      base exec -T "$source" sh -c 'exec pg_dump -Fc --no-tablespaces -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$backup/$pair/database.dump"
      # Validate the archive and confirm no source rows changed while it was captured.
      base exec -T "$source" pg_restore --list < "$backup/$pair/database.dump" > /dev/null
      source_sql "$source" < scripts/replication/fingerprints.sql > "$backup/$pair/after.fingerprints"
      cmp -s "$backup/$pair/source.fingerprints" "$backup/$pair/after.fingerprints" || fail 'Source changed during backup; inspect other writers before retrying'
      (cd "$backup/$pair" && sha256 database.dump roles.sql source.fingerprints > SHA256SUMS)
    done
    base stop "${legacy_databases[@]}"
    assert_stopped "${legacy_databases[@]}"
    printf '%s\n' "$COMPOSE_PROJECT_NAME" > "$backup/project"
    touch "$backup/complete"
    printf '%s\n' "$backup" > "$cutover_state/backup"
    echo "Backup completed: $backup"
    echo 'Applications, ETL and the original databases remain stopped for restore.'
    ;;
  restore)
    backup=${2:?Supply the completed backup directory}
    [ -f "$backup/complete" ] && [ "$(cat "$backup/project")" = "$COMPOSE_PROJECT_NAME" ] || fail 'Backup is incomplete or belongs to another project'
    [ "$(cat "$cutover_state/backup")" = "$backup" ] || fail 'This is not the recorded cutover backup'
    assert_stopped "${paused_services[@]}" "${legacy_databases[@]}"
    for pair in "${pairs[@]}"; do
      (cd "$backup/$pair" && sha256 -c SHA256SUMS >/dev/null)
      if [ -f "$REPLICATION_STATE_ROOT/$pair/restored" ]; then
        echo "$pair already restored; keeping its data"
        continue
      fi
      bash scripts/database-replication.sh "$pair" prepare
      [ "$(target_sql "$pair" <<< "SELECT count(*) FROM pg_tables WHERE schemaname='public'")" = 0 ] || fail "$pair target is not empty; refusing to overwrite it"
      if ! target_sql "$pair" < "$backup/$pair/roles.sql" > "$backup/$pair/role-restore.log" 2>&1; then
        fail "Role restoration failed; inspect the private $pair/role-restore.log"
      fi
      replicated exec -T "$pair-db-1" sh -c 'exec pg_restore --exit-on-error --single-transaction --no-tablespaces -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$backup/$pair/database.dump"
      target_sql "$pair" < scripts/replication/fingerprints.sql > "$backup/$pair/restored.fingerprints"
      cmp -s "$backup/$pair/source.fingerprints" "$backup/$pair/restored.fingerprints" || fail "$pair restored data differs; applications remain stopped"
      touch "$REPLICATION_STATE_ROOT/$pair/restored"
    done
    for pair in "${pairs[@]}"; do
      bash scripts/database-replication.sh "$pair" up
    done
    echo 'Selected databases restored; standbys started. Run verify before activate.'
    ;;
  verify)
    rm -f "$cutover_state/verified"
    for pair in "${pairs[@]}"; do
      [ -f "$REPLICATION_STATE_ROOT/$pair/restored" ] || fail "$pair is not restored"
      bash scripts/database-replication.sh "$pair" verify
    done
    # Check only the sources selected for this cutover.
    configure_analytics_routes verify
    replicated run --rm --no-deps analytics-etl --mode reconcile "${etl_sources[@]}"
    touch "$cutover_state/verified"
    ;;
  activate)
    [ -f "$cutover_state/verified" ] || fail 'Run verify successfully before activate'
    assert_stopped "${legacy_databases[@]}"
    # Once any writer can start, rollback to old volumes would lose new writes.
    touch "$cutover_state/activated"
    replicated up -d --no-deps "${apps[@]}"
    configure_analytics_routes active
    replicated up -d --no-deps analytics-scheduler
    echo 'Selected apps started on replicated databases. Check health and the team game flow.'
    ;;
  rollback-before-activation)
    [ -f "$cutover_state/backup" ] || fail 'No recorded cutover exists'
    [ ! -f "$cutover_state/activated" ] || fail 'Writes may exist in the new clusters; reverse migration needs a fresh backup and review'
    base stop "${paused_services[@]}"
    for pair in "${pairs[@]}"; do
      if [ -f "$REPLICATION_STATE_ROOT/$pair/primary" ]; then
        bash scripts/database-replication.sh "$pair" stop
      fi
    done
    rm -f "$cutover_state/verified"
    touch "$cutover_state/rolled-back"
    base up -d "${legacy_databases[@]}"
    base up -d --no-deps "${apps[@]}"
    configure_analytics_routes active
    replicated up -d --no-deps analytics-scheduler
    echo 'Selected legacy apps and Analytics resumed. Backups and replica volumes were retained.'
    ;;
  resume-analytics)
    configure_analytics_routes active
    replicated up -d --no-deps analytics-scheduler
    ;;
  *) fail 'Usage: replication-cutover.sh [player|session] backup|restore BACKUP_DIRECTORY|verify|activate|rollback-before-activation|resume-analytics' ;;
esac

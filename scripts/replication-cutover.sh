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
source_sql() { base exec -T "$1-db" sh -c 'exec psql -XAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; }
target_sql() { replicated exec -T "$1-db-1" sh -c 'exec psql -XAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'; }
assert_stopped() {
  local cid service
  for service in "$@"; do
    for cid in $(base ps -a -q "$service"); do
      [ "$(docker inspect -f '{{.State.Running}}' "$cid")" = false ] || fail "$service is still running; keep writes paused"
    done
  done
}
mkdir -p "$REPLICATION_STATE_ROOT"
mkdir "$REPLICATION_STATE_ROOT/cutover-lock" 2>/dev/null || fail 'Another cutover or an interrupted command holds the lock'
trap 'rmdir "$REPLICATION_STATE_ROOT/cutover-lock"' EXIT
for pair in moderation discord-dms; do
  [ ! -d "$REPLICATION_STATE_ROOT/$pair/lock" ] || fail "$pair has an active or interrupted database operation"
done
export CPR_CUTOVER_IN_PROGRESS=1
[ ! -f "$REPLICATION_STATE_ROOT/rolled-back" ] || fail 'This cutover was rolled back; its snapshots are stale. Review and reset only the new replica volumes/state before a fresh cutover.'
case "${1:-}" in
  backup)
    [ ! -f "$REPLICATION_STATE_ROOT/activated" ] || fail 'Already activated; a new backup of stale legacy databases is not a rollback plan'
    replicated config --quiet
    for pair in moderation discord-dms; do
      [ ! -f "$REPLICATION_STATE_ROOT/$pair/restored" ] || fail 'A restore is already recorded; inspect it instead of replacing the backup'
      [ "$(source_sql "$pair" <<< "SELECT count(*) FROM pg_roles WHERE rolname='replicator'")" = 0 ] || fail 'Source already contains reserved replicator role; review before migration'
    done
    base stop moderation-service discord-dms-service analytics-scheduler analytics-etl
    assert_stopped moderation-service discord-dms-service analytics-scheduler analytics-etl
    backup="$PWD/.replication-backups/$COMPOSE_PROJECT_NAME/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$(dirname "$backup")"
    mkdir "$backup"
    for pair in moderation discord-dms; do
      mkdir "$backup/$pair"
      source_sql "$pair" < scripts/replication/export-roles.sql > "$backup/$pair/roles.sql"
      source_sql "$pair" < scripts/replication/fingerprints.sql > "$backup/$pair/source.fingerprints"
      base exec -T "$pair-db" sh -c 'exec pg_dump -Fc --no-tablespaces -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$backup/$pair/database.dump"
      # Validate the archive and confirm no source rows changed while it was captured.
      base exec -T "$pair-db" pg_restore --list < "$backup/$pair/database.dump" > /dev/null
      source_sql "$pair" < scripts/replication/fingerprints.sql > "$backup/$pair/after.fingerprints"
      cmp -s "$backup/$pair/source.fingerprints" "$backup/$pair/after.fingerprints" || fail 'Source changed during backup; inspect other writers before retrying'
      (cd "$backup/$pair" && shasum -a 256 database.dump roles.sql source.fingerprints > SHA256SUMS)
    done
    base stop moderation-db discord-dms-db
    assert_stopped moderation-db discord-dms-db
    printf '%s\n' "$COMPOSE_PROJECT_NAME" > "$backup/project"
    touch "$backup/complete"
    printf '%s\n' "$backup" > "$REPLICATION_STATE_ROOT/backup"
    echo "Backup completed: $backup"
    echo 'Applications, ETL and the original databases remain stopped for restore.'
    ;;
  restore)
    backup=${2:?Supply the completed backup directory}
    [ -f "$backup/complete" ] && [ "$(cat "$backup/project")" = "$COMPOSE_PROJECT_NAME" ] || fail 'Backup is incomplete or belongs to another project'
    [ "$(cat "$REPLICATION_STATE_ROOT/backup")" = "$backup" ] || fail 'This is not the recorded cutover backup'
    assert_stopped moderation-service discord-dms-service analytics-scheduler analytics-etl moderation-db discord-dms-db
    for pair in moderation discord-dms; do
      (cd "$backup/$pair" && shasum -a 256 -c SHA256SUMS >/dev/null)
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
    for pair in moderation discord-dms; do
      bash scripts/database-replication.sh "$pair" up
    done
    echo 'Both databases restored and migrated; standbys started. Run verify before activate.'
    ;;
  verify)
    rm -f "$REPLICATION_STATE_ROOT/verified"
    for pair in moderation discord-dms; do
      [ -f "$REPLICATION_STATE_ROOT/$pair/restored" ] || fail "$pair is not restored"
      bash scripts/database-replication.sh "$pair" verify
    done
    # Uses the preserved restricted reader credentials through the new proxies.
    replicated run --rm --no-deps analytics-etl --mode reconcile --source moderation-service --source discord-dms-service
    touch "$REPLICATION_STATE_ROOT/verified"
    ;;
  activate)
    [ -f "$REPLICATION_STATE_ROOT/verified" ] || fail 'Run verify successfully before activate'
    assert_stopped moderation-db discord-dms-db
    # Once any writer can start, rollback to old volumes would lose new writes.
    touch "$REPLICATION_STATE_ROOT/activated"
    replicated up -d --no-deps moderation-service discord-dms-service analytics-scheduler
    echo 'Replicated writers and ETL are active. Check health and the team game flow.'
    ;;
  rollback-before-activation)
    [ -f "$REPLICATION_STATE_ROOT/backup" ] || fail 'No recorded cutover exists'
    [ ! -f "$REPLICATION_STATE_ROOT/activated" ] || fail 'Writes may exist in the new clusters; reverse migration needs a fresh backup and review'
    base stop moderation-service discord-dms-service analytics-scheduler analytics-etl
    for pair in moderation discord-dms; do
      if [ -f "$REPLICATION_STATE_ROOT/$pair/primary" ]; then
        bash scripts/database-replication.sh "$pair" stop
      fi
    done
    rm -f "$REPLICATION_STATE_ROOT/verified"
    touch "$REPLICATION_STATE_ROOT/rolled-back"
    base up -d moderation-db discord-dms-db
    base up -d --no-deps moderation-service discord-dms-service analytics-scheduler
    echo 'Original deployment resumed. Existing backups and replica volumes were retained.'
    ;;
  *) fail 'Usage: replication-cutover.sh backup|restore BACKUP_DIRECTORY|verify|activate|rollback-before-activation' ;;
esac

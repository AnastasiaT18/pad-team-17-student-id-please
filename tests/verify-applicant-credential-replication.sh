#!/usr/bin/env bash
# Live check of the Applicant and Credential database clusters (Lab 5, Grade 5), on disposable data:
# move a running PostgreSQL 16 database into the cluster, replicate to two standbys, fail over, let the
# application reconnect, rebuild the old primary as a standby and read through the analytics DSN.
#
#   bash tests/verify-applicant-credential-replication.sh              # both clusters, one after the other
#   bash tests/verify-applicant-credential-replication.sh applicant    # one of them
#
# Needs Docker Compose 2.24.4+, jq and Bash 3.2+. Pulls the two service images and postgres:16-alpine,
# postgres:18, curlimages/curl. It uses its own Compose project and temporary directory; it never touches
# the volumes or containers of a running CPR stack.
set -euo pipefail
export LC_ALL=C
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APPLICANT_SERVICE_IMAGE=${APPLICANT_SERVICE_IMAGE:-kutulin/pad-17-applicant-service:4.1.0}
CREDENTIAL_SERVICE_IMAGE=${CREDENTIAL_SERVICE_IMAGE:-kutulin/pad-17-credential-service:4.1.0}
PROJECT=pad17-g5-$$
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pad17-g5.XXXXXX")
PASS_COUNT=0
die() {
  echo "FAIL: $*" >&2
  docker compose -p "$PROJECT" --env-file "$WORK/env" -f "$WORK/docker-compose.yml" -f "$WORK/docker-compose.replication.yml" logs --tail 12 --no-color 2>/dev/null | cut -c1-200 >&2 || true
  exit 1
}
ok()  { PASS_COUNT=$((PASS_COUNT + 1)); echo "  ok   $*"; }
step() { printf '\n== %s\n' "$*"; }

command -v jq >/dev/null || die 'jq is required'
trap 'docker compose -p "$PROJECT" --env-file "$WORK/env" -f "$WORK/docker-compose.yml" -f "$WORK/docker-compose.replication.yml" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# ---- a private copy of the CPR files: no fixed container names, one replica per app (a Spring JVM is the costly part),
# ---- apps without Session/Broker/Discovery ----
mkdir -p "$WORK/infrastructure"
cp -R "$SRC/infrastructure/replication" "$WORK/infrastructure/replication"
cp "$SRC/docker-compose.replication.yml" "$WORK/"
awk '/^    container_name:/ { next }
     /^      SERVICE_DISCOVERY_URL:/ { next }
     /^      replicas: 2$/ { print "      replicas: 1"; next }
     /^      SESSION_DIRECTORY: grpc$/ { print "      SESSION_DIRECTORY: mock"; print "      MESSAGING_ENABLED: \"false\""; print "      JAVA_TOOL_OPTIONS: \"-XX:TieredStopAtLevel=1 -XX:+UseSerialGC\""; next }
     { print }' "$SRC/docker-compose.yml" | sed -e "s#kutulin/pad-17-applicant-service:\${APPLICANT_VERSION:-[0-9.]*}#$APPLICANT_SERVICE_IMAGE#" \
        -e "s#kutulin/pad-17-credential-service:\${CREDENTIAL_VERSION:-[0-9.]*}#$CREDENTIAL_SERVICE_IMAGE#" > "$WORK/docker-compose.yml"
cp "$SRC/.env.example" "$WORK/env"
rand() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }
{
  echo "APPLICANT_DB_PASSWORD=$(rand)"; echo "CREDENTIAL_DB_PASSWORD=$(rand)"
  echo "APPLICANT_REPLICATION_PASSWORD=$(rand)"; echo "CREDENTIAL_REPLICATION_PASSWORD=$(rand)"
  echo "SERVER_RULES_REPLICATION_PASSWORD=$(rand)"; echo "UNIVERSITY_RECORD_REPLICATION_PASSWORD=$(rand)"
  echo 'MODERATION_REPLICATION_APP_IMAGE=unused/moderation:none'; echo 'MODERATION_DATABASE_IMAGE=unused/moderation-postgres:none'
  echo 'DISCORD_DMS_REPLICATION_APP_IMAGE=unused/discord:none'; echo 'DISCORD_DMS_DATABASE_IMAGE=unused/discord-postgres:none'
  echo "COMPOSE_PROJECT_NAME=$PROJECT"
} >> "$WORK/env"
export CPR_PROJECT_NAME=$PROJECT CPR_ENV_FILE=$WORK/env
# Generous: a laptop running a game next to Docker answers slowly, and a node that times out counts as unavailable.
export HA_SQL_TIMEOUT=${HA_SQL_TIMEOUT:-60}
CLUSTER="bash $WORK/infrastructure/replication/cluster.sh"
legacy_compose() { docker compose -p "$PROJECT" --env-file "$WORK/env" -f "$WORK/docker-compose.yml" "$@"; }
full_compose()   { REPLICATION_STATE_ROOT="$WORK/.replication/$PROJECT" docker compose -p "$PROJECT" --env-file "$WORK/env" -f "$WORK/docker-compose.yml" -f "$WORK/docker-compose.replication.yml" "$@"; }
envval() { sed -n "s/^$1=//p" "$WORK/env" | tail -n 1; }

http() { # METHOD URL [JSON] -> prints "status body"
  docker run --rm --network "${PROJECT}_default" curlimages/curl:latest -s -m 8 -w ' %{http_code}' -X "$1" -H 'Content-Type: application/json' ${3:+-d "$3"} "$2" 2>/dev/null || true
}
wait_for() { # SECONDS DESCRIPTION COMMAND...
  local limit=$1 what=$2 start=$SECONDS; shift 2
  until "$@" >/dev/null 2>&1; do (( SECONDS - start < limit )) || die "timed out waiting for $what"; sleep 2; done
}
psql_in() { # SERVICE DATABASE-QUERY (as the database owner, through the compose project that is active)
  local compose=$1 service=$2; shift 2
  printf '%s\n' "$1" | $compose exec -T "$service" sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -A -t -v ON_ERROR_STOP=1' 2>&1
}
app_up() { # NAME URL: waits until the application answers /health with 200
  wait_for "${APP_START_SECONDS:-600}" "$1 answering" bash -c "[[ \"\$(docker run --rm --network ${PROJECT}_default curlimages/curl:latest -s -o /dev/null -m 4 -w '%{http_code}' $2/health)\" == 200 ]]"
}
warm() { # URL: GET until the application answers 200 (the first requests after a JVM start can be slow); no writes
  local i status=000
  for i in $(seq 1 30); do
    status=$(http GET "$1" | awk '{print $NF}')
    [[ "$status" == 200 ]] && return 0
    sleep 3
  done
  die "$1 did not answer 200 (last status $status)"
}
rows() { psql_in full_compose "$1" "SELECT count(*) FROM $2;" | tr -d '[:space:]'; }

verify_cluster() {
  local name=$1 table url columns reader_grant
  local db=$name-db app=$name-service dbname=$name user pass
  case $name in
    applicant) table=applicants; url=http://applicant-service:8081
      columns='"applicant_id","session_id","major","year","university_status","role","created_at"' ;;
    credential) table=credentials; url=http://credential-service:8082
      columns='"applicant_id","student_id_doc_valid","student_id_doc_issue","enrollment_confirmation_valid","enrollment_confirmation_issue","created_at"' ;;
  esac
  user=$(envval "$(echo "$name" | tr a-z A-Z)_DB_USER"); pass=$(envval "$(echo "$name" | tr a-z A-Z)_DB_PASSWORD")
  local reader_pass; reader_pass=$(rand)
  local session=00000000-0000-4000-8000-000000000001

  step "$name: the original PostgreSQL 16 database with some data and its analytics reader"
  legacy_compose up -d --no-deps --wait "$db" >/dev/null
  legacy_compose up -d --no-deps "$app" >/dev/null
  app_up "$app" "$url"
  [[ "$(psql_in legacy_compose "$db" 'SHOW server_version_num;')" == 16* ]] || die 'the original database is not PostgreSQL 16'
  ok "legacy database is PostgreSQL 16, application is up"
  psql_in legacy_compose "$db" "CREATE ROLE analytics_reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD '$reader_pass';
    GRANT CONNECT ON DATABASE $dbname TO analytics_reader; GRANT USAGE ON SCHEMA public TO analytics_reader;
    GRANT SELECT ($columns) ON public.$table TO analytics_reader; ALTER ROLE analytics_reader SET default_transaction_read_only = on;" >/dev/null
  local i
  warm "$url/$table"
  for i in 1 2 3 4 5; do
    [[ "$(http POST "$url/${table}" "{\"session_id\":\"$session\"}")" == *" 201" ]] || die "creating a record through the legacy $app failed"
  done
  local before; before=$(psql_in legacy_compose "$db" "SELECT count(*) FROM $table;" | tr -d '[:space:]')
  [[ "$before" == 5 ]] || die "expected 5 rows, found $before"
  ok "5 rows written through the application"

  step "$name: prepare, enable (dump, restore into the PG18 primary, compare, start the standbys)"
  $CLUSTER "$name" prepare
  $CLUSTER "$name" enable
  wait_for 90 "both standbys streaming" bash -c "[[ \$($CLUSTER $name status | grep -c 'streaming from') == 2 ]]"
  [[ "$(psql_in full_compose "$db" 'SHOW server_version_num;')" == 18* ]] || die 'the primary is not PostgreSQL 18'
  [[ "$(rows "$db" "$table")" == 5 ]] || die 'the primary lost rows in the move'
  for i in 1 2; do
    wait_for 60 "standby $i to hold the rows" bash -c "[[ \"\$(printf 'SELECT count(*) FROM $table;' | docker compose -p $PROJECT --env-file $WORK/env -f $WORK/docker-compose.yml -f $WORK/docker-compose.replication.yml exec -T $db-standby-$i sh -c 'export PGPASSWORD=\$POSTGRES_PASSWORD; psql -h 127.0.0.1 -U \$POSTGRES_USER -d \$POSTGRES_DB -X -A -t' | tr -d '[:space:]')\" == 5 ]]"
  done
  ok "5 rows moved to the PG18 primary and replicated to both standbys"
  local out; out=$(psql_in full_compose "$db-standby-1" "INSERT INTO $table (applicant_id) VALUES (gen_random_uuid());" || true)
  [[ "$out" == *"read-only"* ]] || die "a standby accepted a write: $out"
  ok "a standby refuses writes (read-only transaction)"
  app_up "$app" "$url"
  local status=000
  for i in $(seq 1 20); do
    status=$(http GET "$url/$table" | awk '{print $NF}')
    [[ "$status" == 200 ]] && break
    sleep 3
  done
  [[ "$status" == 200 ]] || die "$app does not answer on the new cluster (last status $status)"
  for i in $(seq 1 20); do
    status=$(http POST "$url/$table" "{\"session_id\":\"$session\"}" | awk '{print $NF}')
    [[ "$status" == 201 ]] && break
    sleep 3
  done
  [[ "$status" == 201 ]] || die "$app cannot write on the new cluster (last status $status)"
  wait_for 30 "the new write on both standbys" bash -c "[[ \"\$($CLUSTER $name state $db-standby-1 | cut -d'|' -f1)\" == t ]]"
  ok "$app reads and writes through the multi-host JDBC URL"

  step "$name: reader through the analytics DSN"
  local hosts="$db:5432,$db-standby-1:5432,$db-standby-2:5432"
  local primary_dsn="postgresql://analytics_reader:$reader_pass@$hosts/$dbname?target_session_attrs=primary&connect_timeout=2"
  local readwrite_dsn="postgresql://analytics_reader:$reader_pass@$hosts/$dbname?target_session_attrs=read-write&connect_timeout=2"
  reader() { docker run --rm --network "${PROJECT}_default" postgres:18 psql "$1" -X -A -t -c "SELECT count(*) FROM $table;" 2>&1 | tr -d '[:space:]'; }
  [[ "$(reader "$primary_dsn")" == 6 ]] || die 'the analytics reader could not read the primary with target_session_attrs=primary'
  ok "target_session_attrs=primary reads the 6 rows (the reader kept its password and column grants through the move)"
  [[ "$(reader "$readwrite_dsn")" != 6 ]] || die 'target_session_attrs=read-write unexpectedly worked for the read-only reader'
  ok "target_session_attrs=read-write is refused for a read-only reader, which is why the DSNs use primary"

  step "$name: the primary fails, a standby is promoted, the application reconnects"
  $CLUSTER "$name" failover "$db"
  local primary; primary=$($CLUSTER "$name" primary)
  [[ "$primary" != "$db" ]] || die 'the old primary is still the primary'
  ok "promoted $primary"
  full_compose start "$db" >/dev/null 2>&1 || true
  sleep 6
  [[ "$(docker inspect -f '{{.State.Running}}' "$(full_compose ps -a -q "$db")")" == false ]] || die 'the fenced old primary started again'
  ok "the fenced old primary refuses to start (persistent FENCED guard)"
  status=000
  for i in $(seq 1 60); do
    status=$(http POST "$url/$table" "{\"session_id\":\"$session\"}" | awk '{print $NF}')
    [[ "$status" == 201 ]] && break
    sleep 2
  done
  [[ "$status" == 201 ]] || die "$app did not reconnect to the new primary (last status $status)"
  [[ "$(rows "$primary" "$table")" == 7 ]] || die 'the new primary does not hold the earlier rows plus the new write'
  ok "$app reconnected on its own: the 6 earlier rows are there and a 7th write succeeded"

  step "$name: rebuild the old primary as a standby"
  $CLUSTER "$name" rejoin "$db"
  wait_for 90 "two standbys streaming again" bash -c "[[ \$($CLUSTER $name status | grep -c 'streaming from') == 2 ]]"
  wait_for 60 "the rebuilt node to hold 7 rows" bash -c "[[ \"\$(printf 'SELECT count(*) FROM $table;' | docker compose -p $PROJECT --env-file $WORK/env -f $WORK/docker-compose.yml -f $WORK/docker-compose.replication.yml exec -T $db sh -c 'export PGPASSWORD=\$POSTGRES_PASSWORD; psql -h 127.0.0.1 -U \$POSTGRES_USER -d \$POSTGRES_DB -X -A -t' | tr -d '[:space:]')\" == 7 ]]"
  ok "one primary and two streaming standbys again, all with 7 rows"
  full_compose stop "$app" "$db" "$db-standby-1" "$db-standby-2" >/dev/null 2>&1 || true
}

clusters=("$@"); [[ ${#clusters[@]} -gt 0 ]] || clusters=(applicant credential)
for c in "${clusters[@]}"; do
  case $c in applicant|credential) verify_cluster "$c" ;; *) die "unknown cluster $c" ;; esac
done
printf '\nPASS: %d checks (%s)\n' "$PASS_COUNT" "${clusters[*]}"

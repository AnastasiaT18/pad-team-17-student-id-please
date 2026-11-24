#!/usr/bin/env bash
# Live check of Applicant and Credential as two-phase commit participants (Lab 5, Grade 8), over real gRPC
# and real PostgreSQL, with the Message Broker's contract (proto/transactions.proto) on port 9091 behind the
# transaction token. It plays the coordinator: Applicant prepares, its result goes to Credential, then both
# commit - or both roll back - and the script checks what is visible, what is remembered and what is refused.
#
#   bash tests/verify-two-phase-participants.sh
#
# Needs Docker and jq. Pulls the two service images (default 4.2.0), postgres:16-alpine, curlimages/curl and
# fullstorydev/grpcurl. It uses its own network and containers and removes them at the end.
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APPLICANT_IMAGE=${APPLICANT_IMAGE:-kutulin/pad-17-applicant-service:4.2.0}
CREDENTIAL_IMAGE=${CREDENTIAL_IMAGE:-kutulin/pad-17-credential-service:4.2.0}
NET=pad17-2pc-$$
TOKEN_APPLICANT=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
TOKEN_CREDENTIAL=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
PASS_COUNT=0
die() { echo "FAIL: $*" >&2; docker logs --tail 15 "$NET-applicant" >&2 2>/dev/null || true; docker logs --tail 15 "$NET-credential" >&2 2>/dev/null || true; exit 1; }
ok() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  ok   $*"; }
step() { printf '\n== %s\n' "$*"; }
command -v jq >/dev/null || die 'jq is required'
trap 'docker rm -f "$NET-applicant" "$NET-credential" "$NET-applicant-db" "$NET-credential-db" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true' EXIT

docker network create "$NET" >/dev/null
for svc in applicant credential; do
  docker run -d --name "$NET-$svc-db" --network "$NET" -e POSTGRES_DB=$svc -e POSTGRES_USER=$svc -e POSTGRES_PASSWORD=secret postgres:16-alpine >/dev/null
done
start_app() { # SERVICE IMAGE TOKEN
  docker run -d --name "$NET-$1" --network "$NET" -e TRANSACTION_TOKEN="$3" -e DB_HOST="$NET-$1-db" -e DB_NAME=$1 -e DB_USER=$1 -e DB_PASSWORD=secret \
    -e SESSION_DIRECTORY=mock -e MESSAGING_ENABLED=false -e JAVA_TOOL_OPTIONS="-XX:TieredStopAtLevel=1 -XX:+UseSerialGC" "$2" >/dev/null
}
wait_up() { # SERVICE PORT
  local i
  for i in $(seq 1 120); do
    [[ "$(docker run --rm --network "$NET" curlimages/curl:latest -s -o /dev/null -m 4 -w '%{http_code}' "http://$NET-$1:$2/health" 2>/dev/null || true)" == 200 ]] && return 0
    sleep 5
  done
  die "$1 did not come up"
}
sleep 8
start_app applicant "$APPLICANT_IMAGE" "$TOKEN_APPLICANT"; start_app credential "$CREDENTIAL_IMAGE" "$TOKEN_CREDENTIAL"
wait_up applicant 8081; wait_up credential 8082

token_of() { [[ "$1" == applicant ]] && echo "$TOKEN_APPLICANT" || echo "$TOKEN_CREDENTIAL"; }
call() { # SERVICE METHOD JSON -> prints the JSON answer, or the gRPC error line
  docker run --rm --network "$NET" -v "$SRC/proto:/proto:ro" fullstorydev/grpcurl:latest -plaintext -import-path /proto \
    -proto transactions.proto -H "x-transaction-token: $(token_of "$1")" -d "$3" "$NET-$1:9091" \
    "pad.transactions.v1.TransactionParticipant/$2" 2>&1 || true
}
rows() { docker exec "$NET-$1-db" psql -U "$1" -d "$1" -tAc "SELECT count(*) FROM $2;" | tr -d '[:space:]'; }
prepare() { # SERVICE TX PAYLOAD-JSON-STRING
  call "$1" Prepare "$(jq -nc --arg t "$2" --arg p "$3" --arg o "$1.initialize.v1" '{transaction_id:$t, operation:$o, payload_json:$p}')"
}
decide() { call "$1" "$2" "$(jq -nc --arg t "$3" '{transaction_id:$t}')"; }
status() { call "$1" Status "$(jq -nc --arg t "$2" '{transaction_id:$t}')" | jq -r '.state'; }
SESSION=00000000-0000-4000-8000-000000000001
T1=$(uuidgen | tr A-Z a-z); T2=$(uuidgen | tr A-Z a-z); T3=$(uuidgen | tr A-Z a-z)

step "0. The token: a call without it, or with another one, is refused"
NO_TOKEN=$(docker run --rm --network "$NET" -v "$SRC/proto:/proto:ro" fullstorydev/grpcurl:latest -plaintext -import-path /proto \
  -proto transactions.proto -d '{"transaction_id":"x"}' "$NET-applicant:9091" pad.transactions.v1.TransactionParticipant/Status 2>&1 || true)
[[ "$NO_TOKEN" == *Unauthenticated* ]] || die "a call without the token was answered: $NO_TOKEN"
WRONG=$(docker run --rm --network "$NET" -v "$SRC/proto:/proto:ro" fullstorydev/grpcurl:latest -plaintext -import-path /proto \
  -proto transactions.proto -H "x-transaction-token: $TOKEN_CREDENTIAL" -d '{"transaction_id":"x"}' "$NET-applicant:9091" \
  pad.transactions.v1.TransactionParticipant/Status 2>&1 || true)
[[ "$WRONG" == *Unauthenticated* ]] || die "Credential's token was accepted by Applicant: $WRONG"
ok "no token and the other service's token are both UNAUTHENTICATED"

step "1. Prepare: Applicant, then Credential with Applicant's result - nothing is visible yet"
A=$(prepare applicant "$T1" "{\"session_id\":\"$SESSION\"}")
[[ "$(jq -r .state <<<"$A")" == PREPARED && "$(jq -r .transactionId <<<"$A")" == "$T1" ]] || die "Applicant did not prepare: $A"
OUT=$(jq -r .resultJson <<<"$A")
APPLICANT_ID=$(jq -r .applicant_id <<<"$OUT")
C=$(prepare credential "$T1" "$OUT")
[[ "$(jq -r .state <<<"$C")" == PREPARED ]] || die "Credential did not prepare: $C"
[[ "$(jq -r .resultJson <<<"$C" | jq -r .applicant_id)" == "$APPLICANT_ID" ]] || die 'Credential forged documents for another applicant'
ok "both prepared transaction $T1 for applicant $APPLICANT_ID"
[[ "$(rows applicant applicants)" == 0 && "$(rows credential credentials)" == 0 ]] || die 'a prepared transaction is already visible'
[[ "$(rows applicant two_phase_transactions)" == 1 && "$(rows credential two_phase_transactions)" == 1 ]] || die 'the prepared state is not stored'
ok "nothing in applicants or credentials; the prepared state is in two_phase_transactions"
[[ "$(prepare applicant "$T1" "{\"session_id\":\"$SESSION\"}" | jq -r .resultJson)" == "$OUT" ]] || die 'preparing again gave another answer'
ok "preparing again returns the same answer"
[[ "$(prepare applicant "$T1" '{"session_id":"00000000-0000-4000-8000-000000000002"}' | jq -r .state)" == ABORTED ]] || die 'the same id with other data was accepted'
ok "the same transaction id with other data is answered ABORTED, with the reason"

step "2. The state survives a restart of both services"
docker restart "$NET-applicant" "$NET-credential" >/dev/null
wait_up applicant 8081; wait_up credential 8082
[[ "$(status applicant "$T1")" == PREPARED && "$(status credential "$T1")" == PREPARED ]] || die 'a restart lost the prepared transaction'
ok "after the restart both still answer PREPARED"

step "3. Commit: the applicant and its documents become visible, and repeating changes nothing"
[[ "$(decide applicant Commit "$T1" | jq -r .state)" == COMMITTED && "$(decide credential Commit "$T1" | jq -r .state)" == COMMITTED ]] || die 'commit failed'
[[ "$(rows applicant applicants)" == 1 && "$(rows credential credentials)" == 1 ]] || die 'commit did not create the rows'
ok "1 applicant and 1 set of documents"
[[ "$(decide applicant Commit "$T1" | jq -r .state)" == COMMITTED && "$(rows applicant applicants)" == 1 ]] || die 'a second commit changed something'
ok "committing again answers COMMITTED and creates nothing"
[[ "$(decide applicant Rollback "$T1")" == *FailedPrecondition* ]] || die 'a rollback after the commit was accepted'
ok "a rollback after the commit is refused (FAILED_PRECONDITION)"
[[ "$(rows applicant "applicants WHERE applicant_id = '$APPLICANT_ID'")" == 1 && "$(rows credential "credentials WHERE applicant_id = '$APPLICANT_ID'")" == 1 ]] || die 'the committed rows are not the prepared applicant'
ok "the committed applicant is the one that was prepared"

step "4. Rollback: nothing is created, and a later commit is refused"
A=$(prepare applicant "$T2" "{\"session_id\":\"$SESSION\"}"); OUT=$(jq -r .resultJson <<<"$A")
prepare credential "$T2" "$OUT" >/dev/null
[[ "$(decide applicant Rollback "$T2" | jq -r .state)" == ABORTED && "$(decide credential Rollback "$T2" | jq -r .state)" == ABORTED ]] || die 'rollback failed'
[[ "$(rows applicant applicants)" == 1 && "$(rows credential credentials)" == 1 ]] || die 'a rolled back transaction left rows behind'
ok "rows unchanged after the rollback (still 1 and 1)"
[[ "$(decide applicant Commit "$T2")" == *FailedPrecondition* ]] || die 'a commit after the rollback was accepted'
ok "a commit after the rollback is refused (FAILED_PRECONDITION)"
[[ "$(status applicant "$T2")" == ABORTED ]] || die 'the rollback is not remembered'
ok "the decision is remembered: ABORTED"

step "5. A rollback that arrives first refuses the late prepare; unknown transactions"
[[ "$(decide applicant Rollback "$T3" | jq -r .state)" == ABORTED ]] || die 'rollback of an unknown transaction failed'
[[ "$(prepare applicant "$T3" "{\"session_id\":\"$SESSION\"}" | jq -r .state)" == ABORTED ]] || die 'a late prepare was accepted'
ok "rollback before prepare, then the prepare is rejected"
[[ "$(status applicant "$(uuidgen | tr A-Z a-z)")" == UNKNOWN ]] || die 'an unknown transaction was not UNKNOWN'
ok "a transaction never seen is UNKNOWN"
[[ "$(decide credential Commit "$(uuidgen | tr A-Z a-z)")" == *FailedPrecondition* ]] || die 'commit of an unknown transaction was accepted'
ok "committing a transaction that was never prepared is refused"

printf '\nPASS: %d checks\n' "$PASS_COUNT"

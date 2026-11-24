#!/usr/bin/env bash
# Live check of Applicant and Credential as saga participants (Lab 5, Grade 9), over real gRPC and real
# PostgreSQL, with the Message Broker's contract (proto/saga.proto) on port 9091 behind the transaction token.
# It plays the coordinator: Applicant executes, its result goes to Credential, and the steps are then undone in
# reverse order, to check what is visible at once, what is remembered and what is refused.
#
#   bash tests/verify-saga-participants.sh
#
# Needs Docker, jq and uuidgen. Pulls the two service images (default 4.2.0), postgres:16-alpine,
# curlimages/curl and fullstorydev/grpcurl. It uses its own network and containers and removes them at the end.
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/../proto" && pwd)
APPLICANT_IMAGE=${APPLICANT_IMAGE:-kutulin/pad-17-applicant-service:4.2.0}
CREDENTIAL_IMAGE=${CREDENTIAL_IMAGE:-kutulin/pad-17-credential-service:4.2.0}
NET=pad17-saga-$$
TOKEN_APPLICANT=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
TOKEN_CREDENTIAL=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
PASS_COUNT=0
die() { echo "FAIL: $*" >&2; docker logs --tail 20 "$NET-applicant" >&2 2>/dev/null || true; docker logs --tail 20 "$NET-credential" >&2 2>/dev/null || true; exit 1; }
ok() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  ok   $*"; }
step() { printf '\n== %s\n' "$*"; }
trap 'docker rm -f "$NET-applicant" "$NET-credential" "$NET-applicant-db" "$NET-credential-db" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true' EXIT
docker network create "$NET" >/dev/null
for svc in applicant credential; do
  docker run -d --name "$NET-$svc-db" --network "$NET" -e POSTGRES_DB=$svc -e POSTGRES_USER=$svc -e POSTGRES_PASSWORD=secret postgres:16-alpine >/dev/null
done
start_app() { docker run -d --name "$NET-$1" --network "$NET" -e TRANSACTION_TOKEN="$3" -e DB_HOST="$NET-$1-db" -e DB_NAME=$1 -e DB_USER=$1 -e DB_PASSWORD=secret \
    -e SESSION_DIRECTORY=mock -e MESSAGING_ENABLED=false -e JAVA_TOOL_OPTIONS="-XX:TieredStopAtLevel=1 -XX:+UseSerialGC" "$2" >/dev/null; }
rest() { docker run --rm --network "$NET" curlimages/curl:latest -s -o /dev/null -m 6 -w '%{http_code}' "http://$NET-$1:$2$3" 2>/dev/null || true; }
wait_up() { local i; for i in $(seq 1 150); do [[ "$(rest "$1" "$2" /health)" == 200 ]] && return 0; sleep 5; done; die "$1 did not come up"; }
sleep 8
start_app applicant "$APPLICANT_IMAGE" "$TOKEN_APPLICANT"; start_app credential "$CREDENTIAL_IMAGE" "$TOKEN_CREDENTIAL"
wait_up applicant 8081; wait_up credential 8082
token_of() { [[ "$1" == applicant ]] && echo "$TOKEN_APPLICANT" || echo "$TOKEN_CREDENTIAL"; }
call() { docker run --rm --network "$NET" -v "$SRC:/proto:ro" fullstorydev/grpcurl:latest -plaintext -import-path /proto -proto saga.proto \
    -H "x-transaction-token: $(token_of "$1")" -d "$3" "$NET-$1:9091" "pad.saga.v1.SagaParticipant/$2" 2>&1 || true; }
rows() { docker exec "$NET-$1-db" psql -U "$1" -d "$1" -tAc "SELECT count(*) FROM $2;" | tr -d '[:space:]'; }
execute() { call "$1" Execute "$(jq -nc --arg s "$2" --arg p "$3" --arg o "$4" '{saga_id:$s, operation:$o, payload_json:$p}')"; }
compensate() { call "$1" Compensate "$(jq -nc --arg s "$2" --arg o "$3" '{saga_id:$s, operation:$o}')"; }
AOP=applicant.create.v1; COP=credential.create.v1
SESSION=00000000-0000-4000-8000-000000000001; ENDED=00000000-0000-0000-0000-0000000e0d0d
S1=$(uuidgen | tr A-Z a-z); S2=$(uuidgen | tr A-Z a-z); S3=$(uuidgen | tr A-Z a-z); S4=$(uuidgen | tr A-Z a-z)

step "0. The token: no token, or the other service's token, is UNAUTHENTICATED on the saga service"
NO=$(docker run --rm --network "$NET" -v "$SRC:/proto:ro" fullstorydev/grpcurl:latest -plaintext -import-path /proto -proto saga.proto -d '{"saga_id":"x","operation":"applicant.create.v1"}' "$NET-applicant:9091" pad.saga.v1.SagaParticipant/Compensate 2>&1 || true)
[[ "$NO" == *Unauthenticated* ]] || die "no token was answered: $NO"
WRONG=$(docker run --rm --network "$NET" -v "$SRC:/proto:ro" fullstorydev/grpcurl:latest -plaintext -import-path /proto -proto saga.proto -H "x-transaction-token: $TOKEN_CREDENTIAL" -d '{"saga_id":"x","operation":"applicant.create.v1","payload_json":"{}"}' "$NET-applicant:9091" pad.saga.v1.SagaParticipant/Execute 2>&1 || true)
[[ "$WRONG" == *Unauthenticated* ]] || die "the other token was accepted: $WRONG"
ok "no token and another service's token are both UNAUTHENTICATED"

step "1. Execute on Applicant: the applicant is real at once (no second phase)"
A=$(execute applicant "$S1" "{\"session_id\":\"$SESSION\"}" $AOP)
[[ "$(jq -r .state <<<"$A")" == DONE && "$(jq -r .sagaId <<<"$A")" == "$S1" ]] || die "Applicant did not execute: $A"
OUT=$(jq -r .resultJson <<<"$A"); AID=$(jq -r .applicant_id <<<"$OUT")
echo "     result_json keys: $(jq -r 'keys|join(",")' <<<"$OUT")"
ok "DONE, applicant $AID"
[[ "$(rows applicant applicants)" == 1 && "$(rows applicant "saga_steps WHERE state = 'DONE'")" == 1 && "$(rows applicant two_phase_transactions)" == 0 ]] || die 'the applicant is not saved with its saga row'
[[ "$(rest applicant 8081 "/applicants/$AID")" == 200 ]] || die "the applicant is not readable at once: $(rest applicant 8081 "/applicants/$AID")"
ok "REST GET /applicants/$AID answers 200 straight after Execute"
ok "1 applicant, 1 DONE saga row, nothing in two_phase_transactions"
[[ "$(execute applicant "$S1" "{\"session_id\":\"$SESSION\"}" $AOP | jq -r .resultJson)" == "$OUT" && "$(rows applicant applicants)" == 1 ]] || die 'executing again gave another answer or another applicant'
ok "executing again returns the same result_json and creates nothing"
[[ "$(execute applicant "$S1" '{"session_id":"00000000-0000-4000-8000-000000000002"}' $AOP)" == *FailedPrecondition* ]] || die 'other data for the same saga was accepted'
ok "the same saga id with other data is FAILED_PRECONDITION"

step "2. Execute on Credential with Applicant's result"
C=$(execute credential "$S1" "$OUT" $COP)
[[ "$(jq -r .state <<<"$C")" == DONE ]] || die "Credential did not execute: $C"
COUT=$(jq -r .resultJson <<<"$C")
echo "     result_json keys: $(jq -r 'keys|join(",")' <<<"$COUT")"
[[ "$(jq -r .applicant_id <<<"$COUT")" == "$AID" && "$(rows credential credentials)" == 1 && "$(rows credential "saga_steps WHERE state = 'DONE'")" == 1 ]] || die 'the documents are not saved'
ok "DONE, 1 set of documents for the same applicant, readable at once"

step "3. The state survives a restart of both services"
docker restart "$NET-applicant" "$NET-credential" >/dev/null; wait_up applicant 8081; wait_up credential 8082
[[ "$(execute applicant "$S1" "{\"session_id\":\"$SESSION\"}" $AOP | jq -r .resultJson)" == "$OUT" && "$(execute credential "$S1" "$OUT" $COP | jq -r .resultJson)" == "$COUT" ]] || die 'a restart lost the step'
ok "after the restart both answer the same result_json"

step "4. Compensate (reverse order): the applicant and the documents disappear, repeating is harmless"
[[ "$(compensate credential "$S1" $COP | jq -r .state)" == COMPENSATED && "$(compensate applicant "$S1" $AOP | jq -r .state)" == COMPENSATED ]] || die 'compensate failed'
[[ "$(rows applicant applicants)" == 0 && "$(rows credential credentials)" == 0 ]] || die 'compensate left rows behind'
ok "COMPENSATED, 0 applicants and 0 documents"
[[ "$(rest applicant 8081 "/applicants/$AID")" == 404 ]] || die "the applicant is still readable: $(rest applicant 8081 "/applicants/$AID")"
ok "REST GET /applicants/$AID answers 404"
[[ "$(compensate applicant "$S1" $AOP | jq -r .state)" == COMPENSATED ]] || die 'compensating twice failed'
ok "compensating again answers COMPENSATED"
[[ "$(execute applicant "$S1" "{\"session_id\":\"$SESSION\"}" $AOP | jq -r .state)" == COMPENSATED && "$(rows applicant applicants)" == 0 ]] || die 'a late execute created an applicant'
[[ "$(execute credential "$S1" "$OUT" $COP | jq -r .state)" == COMPENSATED && "$(rows credential credentials)" == 0 ]] || die 'a late execute created documents'
ok "an Execute after the Compensate answers COMPENSATED and creates nothing"

step "5. A Compensate that arrives first leaves a tombstone"
[[ "$(compensate applicant "$S2" $AOP | jq -r .state)" == COMPENSATED ]] || die 'compensate of an unknown saga failed'
[[ "$(execute applicant "$S2" "{\"session_id\":\"$SESSION\"}" $AOP | jq -r .state)" == COMPENSATED && "$(rows applicant applicants)" == 0 ]] || die 'a late execute was accepted after the tombstone'
ok "tombstone: the Execute that comes late is COMPENSATED and creates nothing"

step "6. A refused step is an answer (FAILED + reason), remembered, and changes nothing"
F=$(execute applicant "$S3" "{\"session_id\":\"$ENDED\"}" $AOP)
[[ "$(jq -r .state <<<"$F")" == FAILED && "$(jq -r .resultJson <<<"$F" | jq -r .reason)" != "" && "$(rows applicant applicants)" == 0 ]] || die "a shift that is not running was not refused: $F"
echo "     reason: $(jq -r .resultJson <<<"$F" | jq -r .reason)"
[[ "$(rows applicant "saga_steps WHERE state = 'FAILED'")" == 1 && "$(execute applicant "$S3" "{\"session_id\":\"$ENDED\"}" $AOP | jq -r .state)" == FAILED ]] || die 'the refusal is not remembered'
ok "FAILED with the reason, stored, and asking again gives FAILED"
[[ "$(execute credential "$S4" '{"applicant_id":"x"}' $COP | jq -r .state)" == FAILED ]] || die 'a payload that is not an applicant was accepted'
ok "Credential: a payload that is not an applicant is FAILED"

step "7. Unknown operation and invalid saga id"
[[ "$(execute applicant "$S4" '{}' something.else.v1 | jq -r .state)" == UNKNOWN ]] || die 'unknown operation was not UNKNOWN'
ok "an unknown operation is UNKNOWN"
[[ "$(execute applicant "$(printf 'x%.0s' $(seq 1 65))" '{}' $AOP)" == *InvalidArgument* ]] || die 'a 65 character saga id was accepted'
ok "a saga id of 65 characters is INVALID_ARGUMENT"

printf '\nPASS: %d checks\n' "$PASS_COUNT"

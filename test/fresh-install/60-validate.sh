#!/usr/bin/env bash
# Validate the fresh conductor install end-to-end by querying the ingested
# fresh-test telemetry TWO ways and asserting both return the marker:
#   (1) query-api DIRECT with the per-org admin/api key
#   (2) the maestro PROXY path (/api/lakerunner/{instanceId}/query/...) with
#       X-Org-Id + a per-user maestro API key
#
# Exits non-zero if either path is missing the `fresh-test` marker.
#
# Services are ClusterIP, so curls run from a transient in-cluster pod.
set -uo pipefail
CTX="${CTX:-kubepi}"
NS="${NS:-conductor-fresh}"
ORG="${ORG:-11111111-1111-1111-1111-111111111111}"
MARKER="fresh-test"
QUERY='{"q":"{service_name=\"fresh-test\"}","s":"e-6h","e":"now"}'
HELPER=fresh-validate-curl

kc() { command kubectl --context "$CTX" -n "$NS" "$@"; }
PSQL_LR() { kc exec deploy/postgres -- psql -U lakerunner -d lakerunner -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }
PSQL_MAESTRO() { kc exec deploy/postgres -- psql -U maestro -d maestro -tAc "$1" 2>/dev/null; }

echo "==> Resolving credentials and instance id"
# Per-org lakerunner key the maestro provisioner minted (stored in the integration
# credentials; this is the org key query-api validates for direct calls).
ORGKEY=$(PSQL_MAESTRO "SELECT credentials->>'lakerunner-api-key' FROM maestro_integrations WHERE type='lakerunner' AND org_id='$ORG' LIMIT 1;" | tr -d '[:space:]')
# The proxy :instanceId is the lakerunner integration's id.
INSTANCE=$(PSQL_MAESTRO "SELECT id FROM maestro_integrations WHERE type='lakerunner' AND org_id='$ORG' LIMIT 1;" | tr -d '[:space:]')
[ -n "$ORGKEY" ]  || { echo "FAIL: no per-org lakerunner key found in maestro_integrations"; exit 1; }
[ -n "$INSTANCE" ] || { echo "FAIL: no lakerunner integration (instance id) for org $ORG"; exit 1; }
echo "    org key: ${ORGKEY:0:8}...  instance: $INSTANCE"

echo "==> Minting a per-user maestro API key for the proxy path"
# Contract (packages/maestro/src/lib/api-key.ts + db/repositories/api-keys.ts):
#   plaintext = randomBytes(32) hex (64 chars); key_hash = sha256(plaintext) hex;
#   key_prefix = plaintext[0:8]; owner_type='organization', owner_id=<org>,
#   scopes=[] (unrestricted, required so the proxy path is allowed).
USERKEY=$(head -c32 /dev/urandom | xxd -p -c64 | tr -d '\n')
UHASH=$(printf %s "$USERKEY" | shasum -a 256 | cut -d' ' -f1)
UPREFIX=${USERKEY:0:8}
PSQL_MAESTRO "INSERT INTO maestro_api_keys (key_hash, key_prefix, owner_type, owner_id, label, scopes)
  VALUES ('$UHASH','$UPREFIX','organization','$ORG','fresh-test-user','[]'::jsonb)
  ON CONFLICT (key_hash) DO NOTHING;" >/dev/null
echo "    user key: ${USERKEY:0:8}..."

echo "==> Starting in-cluster curl helper"
kc delete pod "$HELPER" --ignore-not-found >/dev/null 2>&1
kc run "$HELPER" --image=curlimages/curl:latest --restart=Never --command -- sleep 900 >/dev/null
# wait for Running
for _ in $(seq 1 30); do
  [ "$(kc get pod "$HELPER" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 2
done

cleanup() { kc delete pod "$HELPER" --ignore-not-found >/dev/null 2>&1 || true; }
trap cleanup EXIT

curl_in() { kc exec "$HELPER" -- curl -sS -m 90 "$@" 2>&1; }

# Retry loop helper: run the curl, grep for marker, retry a few times for
# eventual consistency (ingest/compaction may lag the telemetry send).
query_with_retry() {
  local label="$1" outfile="$2"; shift 2
  local attempt
  for attempt in 1 2 3 4 5 6; do
    curl_in "$@" > "$outfile" 2>&1
    if grep -q "$MARKER" "$outfile"; then
      echo "    [$label] marker found (attempt $attempt)"
      return 0
    fi
    echo "    [$label] marker not yet present (attempt $attempt), retrying in 15s..."
    sleep 15
  done
  return 1
}

echo "==> (1) Direct query-api logs query"
query_with_retry direct /tmp/direct.json \
  -H "x-cardinalhq-api-key: $ORGKEY" -H 'content-type: application/json' \
  -d "$QUERY" \
  "http://conductor-lakerunner-query-api.${NS}.svc:8080/api/v1/logs/query"
DIRECT_OK=$?

echo "==> (2) Maestro proxy logs query"
query_with_retry proxy /tmp/proxy.json \
  -H "X-Org-Id: $ORG" -H "X-CardinalHQ-API-Key: $USERKEY" -H 'content-type: application/json' \
  -d "$QUERY" \
  "http://conductor-maestro-maestro.${NS}.svc:4200/api/lakerunner/${INSTANCE}/query/logs/query"
PROXY_OK=$?

echo
echo "===================== RESULTS ====================="
echo "--- direct response (head) ---"; head -c 400 /tmp/direct.json; echo
echo "--- proxy  response (head) ---"; head -c 400 /tmp/proxy.json; echo
echo "==================================================="

FAIL=0
if [ "$DIRECT_OK" -eq 0 ]; then echo "PASS: query-api DIRECT returned the '$MARKER' data"; else echo "FAIL: query-api DIRECT did NOT return '$MARKER'"; FAIL=1; fi
if [ "$PROXY_OK" -eq 0 ];  then echo "PASS: maestro PROXY returned the '$MARKER' data";  else echo "FAIL: maestro PROXY did NOT return '$MARKER'";  FAIL=1; fi

if [ "$FAIL" -ne 0 ]; then
  echo "FRESH-INSTALL VALIDATION FAILED"
  exit 1
fi
echo "FRESH-INSTALL VALIDATION PASSED (both direct + proxy returned $MARKER)"
exit 0

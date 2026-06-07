#!/usr/bin/env bash
# Task 5 step 3: assert adoption correctness.
#   (a) all conductor pods Ready
#   (b) NO new bootstrap: M_SHARED (shared_cardinal deployment) still 0, and the
#       legacy maestro_integrations row intact + singular (not duplicated)
#   (c) configdb org/bucket counts unchanged from the pre-adoption snapshot
#   (d) existing data still queryable via query-api with the legacy org key
#       (auth accepted -> HTTP 200; no telemetry was ingested so result is empty)
# Reads the pre-adoption snapshot from $SNAP (written by 00-run.sh before 30).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
SNAP="${SNAP:-/tmp/conductor-adopt-snapshot.env}"

FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

echo "==> (a) all conductor pods Ready"
NOTREADY=$(kc get pods -l app.kubernetes.io/instance=conductor --no-headers 2>/dev/null \
  | awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print $1" "$2" "$3}')
if [ -z "$NOTREADY" ]; then pass "all conductor pods Ready"; else fail "not-ready conductor pods:"; echo "$NOTREADY" | sed 's/^/    /'; fi

echo "==> (b) no new bootstrap (M_SHARED==0, legacy integration singular)"
M_SHARED=$(psql_db maestro maestro "SELECT count(*) FROM maestro_lakerunner_deployments WHERE source='shared_cardinal' AND enabled AND is_demo=false AND auto_add_to_all_orgs AND btrim(coalesce(admin_api_url,''))<>'' AND btrim(coalesce(admin_api_key,''))<>'';")
INTEG=$(psql_db maestro maestro "SELECT count(*) FROM maestro_integrations WHERE type='lakerunner';")
M_ORGS=$(psql_db maestro maestro "SELECT count(*) FROM maestro_organizations;")
echo "    M_SHARED=$M_SHARED  lakerunner_integrations=$INTEG  maestro_orgs=$M_ORGS"
[ "$M_SHARED" = "0" ] && pass "no shared_cardinal deployment created (M_SHARED=0)" || fail "adopt created a shared_cardinal deployment (M_SHARED=$M_SHARED)"
[ "$INTEG" = "1" ]    && pass "legacy lakerunner integration intact + singular (count=1)" || fail "lakerunner integration count is $INTEG (expected 1 — duplication?)"

echo "==> (c) configdb org/bucket counts unchanged from pre-adoption snapshot"
# shellcheck disable=SC1090
[ -f "$SNAP" ] && . "$SNAP" || { fail "snapshot $SNAP missing"; SNAP_ORGS=""; SNAP_BUCKETS=""; SNAP_MORGS=""; }
LR_ORGS_NOW=$(psql_db config configdb "SELECT count(*) FROM organizations;")
LR_BUCKETS_NOW=$(psql_db config configdb "SELECT count(*) FROM organization_buckets;")
M_ORGS_NOW="$M_ORGS"
echo "    configdb orgs: snapshot=$SNAP_ORGS now=$LR_ORGS_NOW"
echo "    configdb buckets: snapshot=$SNAP_BUCKETS now=$LR_BUCKETS_NOW"
echo "    maestro orgs: snapshot=$SNAP_MORGS now=$M_ORGS_NOW"
[ -n "$SNAP_ORGS" ]    && [ "$LR_ORGS_NOW" = "$SNAP_ORGS" ]       && pass "configdb organizations unchanged ($LR_ORGS_NOW)" || fail "configdb organizations changed ($SNAP_ORGS -> $LR_ORGS_NOW)"
[ -n "$SNAP_BUCKETS" ] && [ "$LR_BUCKETS_NOW" = "$SNAP_BUCKETS" ] && pass "configdb organization_buckets unchanged ($LR_BUCKETS_NOW)" || fail "configdb organization_buckets changed ($SNAP_BUCKETS -> $LR_BUCKETS_NOW)"
[ -n "$SNAP_MORGS" ]   && [ "$M_ORGS_NOW" = "$SNAP_MORGS" ]       && pass "maestro_organizations unchanged ($M_ORGS_NOW)" || fail "maestro_organizations changed ($SNAP_MORGS -> $M_ORGS_NOW)"

echo "==> (d) legacy org queryable via query-api with the legacy org key"
HELPER=adopt-validate-curl
kc delete pod "$HELPER" --ignore-not-found >/dev/null 2>&1
kc run "$HELPER" --image=curlimages/curl:latest --restart=Never --command -- sleep 300 >/dev/null
for _ in $(seq 1 30); do
  [ "$(kc get pod "$HELPER" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break; sleep 2
done
trap 'kc delete pod "$HELPER" --ignore-not-found >/dev/null 2>&1 || true' EXIT
QUERY='{"q":"{service_name=\"anything\"}","s":"e-1h","e":"now"}'
CODE=""
for attempt in 1 2 3 4 5 6; do
  CODE=$(kc exec "$HELPER" -- curl -sS -m 60 -o /dev/null -w '%{http_code}' \
    -H "x-cardinalhq-api-key: ${LEGACY_KEY}" -H 'content-type: application/json' \
    -d "$QUERY" \
    "http://conductor-lakerunner-query-api.${NS}.svc:8080/api/v1/logs/query" 2>/dev/null)
  echo "    query-api HTTP $CODE (attempt $attempt)"
  [ "$CODE" = "200" ] && break
  sleep 10
done
[ "$CODE" = "200" ] && pass "query-api accepted the legacy org key (HTTP 200 — configdb apikey+profile survived)" \
                    || fail "query-api rejected the legacy org key (HTTP $CODE)"

echo
if [ "$FAIL" -ne 0 ]; then echo "ADOPT ASSERTIONS FAILED"; exit 1; fi
echo "ADOPT ASSERTIONS PASSED"

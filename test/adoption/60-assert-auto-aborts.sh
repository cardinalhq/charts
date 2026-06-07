#!/usr/bin/env bash
# Task 6 step 1: against the SAME legacy-populated external DBs, attempt
# `helm install conductor-auto ... --set bootstrap.mode=auto` and assert it
# FAILS with the detect Job classifying ADOPT_LEGACY. This proves the safety
# net prevents accidental duplication when the operator forgets mode=adopt.
#
# The detect Job's hook-delete-policy is `before-hook-creation,hook-succeeded`,
# so a FAILED detect job is NOT deleted — its pod + logs remain for inspection.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
REL=conductor-auto

FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

echo "==> [auto-abort] cleanup any prior conductor-auto release/job"
helm uninstall "$REL" -n "$NS" >/dev/null 2>&1 || true
kc delete job "${REL}-bootstrap-detect" --ignore-not-found >/dev/null 2>&1 || true

echo "==> [auto-abort] helm install $REL --set bootstrap.mode=auto (expected to FAIL)"
# Supply valid bootstrap.org/bucket so the chart RENDERS under mode=auto (those
# fields are required when bootstrap is active) — the abort we are proving must
# come from the pre-install DETECT Job classifying the legacy DB, NOT from a
# render-time required-field error.
set +e
helm install "$REL" "$ROOT/conductor" -n "$NS" \
  -f "$HERE/conductor-adopt-values.yaml" --set bootstrap.mode=auto \
  --set bootstrap.org.id=11111111-1111-1111-1111-111111111111 \
  --set bootstrap.org.ownerEmail=admin@test.local \
  --set bootstrap.bucket.name=lakerunner \
  --set bootstrap.bucket.endpoint=http://rustfs:9000 \
  --set bootstrap.bucket.usePathStyle=true \
  --set bootstrap.bucket.insecureTls=true \
  --timeout 300s > /tmp/auto-abort-helm.log 2>&1
HELM_RC=$?
set -e 2>/dev/null || true
echo "    helm rc=$HELM_RC"
tail -5 /tmp/auto-abort-helm.log | sed 's/^/    helm: /'

[ "$HELM_RC" -ne 0 ] && pass "helm install aborted (rc=$HELM_RC) under mode=auto on a legacy DB" \
                     || fail "helm install SUCCEEDED under mode=auto on a legacy DB (should have aborted!)"

echo "==> [auto-abort] detect Job log (should show ADOPT_LEGACY)"
# The failed detect job/pod is retained (hook-delete-policy excludes hook-failed).
DETECT_LOG="$(kc logs job/${REL}-bootstrap-detect 2>/dev/null || true)"
if [ -z "$DETECT_LOG" ]; then
  # fall back to the pod by label if the job object query missed
  POD="$(kc get pods -l job-name=${REL}-bootstrap-detect -o name 2>/dev/null | head -1)"
  [ -n "$POD" ] && DETECT_LOG="$(kc logs "$POD" 2>/dev/null || true)"
fi
echo "------- detect job log -------"
echo "$DETECT_LOG" | sed 's/^/    /'
echo "------------------------------"
echo "$DETECT_LOG" | grep -q 'ADOPT_LEGACY' && pass "detect Job classified ADOPT_LEGACY" \
                                            || fail "detect Job did NOT log ADOPT_LEGACY"

echo "==> [auto-abort] assert no shared_cardinal deployment was created by the aborted run"
M_SHARED=$(psql_db maestro maestro "SELECT count(*) FROM maestro_lakerunner_deployments WHERE source='shared_cardinal';")
[ "$M_SHARED" = "0" ] && pass "no shared_cardinal deployment created by aborted auto run (M_SHARED=0)" \
                      || fail "aborted auto run left a shared_cardinal deployment (M_SHARED=$M_SHARED)"

echo "==> [auto-abort] cleanup failed release + retained detect job"
helm uninstall "$REL" -n "$NS" >/dev/null 2>&1 || true
kc delete job "${REL}-bootstrap-detect" --ignore-not-found >/dev/null 2>&1 || true

echo
if [ "$FAIL" -ne 0 ]; then echo "AUTO-ABORT ASSERTIONS FAILED"; exit 1; fi
echo "AUTO-ABORT ASSERTIONS PASSED"

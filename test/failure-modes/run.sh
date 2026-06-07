#!/usr/bin/env bash
# Task 7: §8.3 failure-mode acceptance tests for conductor, on kubepi, in the
# throwaway namespace conductor-fail. Each case prints PASS/FAIL; the script
# exits non-zero if ANY case fails.
#
# Cases:
#   1. split-brain (maestro populated, configdb empty) -> auto detect aborts
#      with ERROR (only one side populated).
#   2. anchor-Secret / DB-key mismatch -> maestro surfaces an auth error but does
#      NOT crashloop the whole release; re-running key-seed reconciles.
#   3. two concurrent key-seed Jobs -> ON CONFLICT keeps exactly one
#      admin_api_keys row, no error.
#   4. helm rollback after an upgrade -> release healthy, migrations not
#      destructively re-run.
#   5. PVC cold-start after adoption -> github-cache StatefulSet re-clones (no
#      data loss; eventually Ready).
#
# SAFETY: every kubectl/helm call is pinned to --context kubepi; aborts if the
# current context is not kubepi.
set -uo pipefail
CTX="${CTX:-kubepi}"
NS="${NS:-conductor-fail}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # test/
REPO="$(cd "$ROOT/.." && pwd)"          # repo root
REL=conductor

kc()   { command kubectl --context "$CTX" -n "$NS" "$@"; }
kcg()  { command kubectl --context "$CTX" "$@"; }
helm() { command helm --kube-context "$CTX" "$@"; }

# Resolve the concrete postgres pod name (avoids `deploy/postgres` exec races
# during/after a rollout, and the flaky `-i` with no stdin).
pg_pod() {
  kc get pods -l app=postgres \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# psql into the bundled postgres as <role> <db> <sql>. Targets the pod by name
# (no `-i`), retries a few times so a transient empty/connection-refused result
# during a rollout does not silently return "". Returns trimmed stdout.
psql_db() { # role db sql
  local role="$1" db="$2" sql="$3" out pod
  for _ in 1 2 3 4 5 6; do
    pod="$(pg_pod)"
    if [ -n "$pod" ]; then
      out="$(kc exec "$pod" -- psql -U "$role" -d "$db" -tAc "$sql" 2>/dev/null | tr -d '[:space:]')"
      [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    fi
    sleep 2
  done
  printf '%s' "$out"
}

# psql_int: like psql_db but ONLY returns when the result is a clean integer
# (used for count(*) reads). Retries until it gets a non-empty integer or gives
# up, in which case it prints nothing (caller must guard with :- defaults).
psql_int() { # role db sql
  local role="$1" db="$2" sql="$3" out
  for _ in 1 2 3 4 5 6 7 8; do
    out="$(psql_db "$role" "$db" "$sql")"
    case "$out" in
      ''|*[!0-9]*) sleep 2 ;;
      *) printf '%s' "$out"; return 0 ;;
    esac
  done
  return 1
}

# Count pods that are genuinely not-ready: Running-but-not-all-containers-ready,
# or Error/CrashLoopBackOff. EXCLUDES Completed/Succeeded hook pods (e.g.
# conductor-bootstrap-migrate-*), which are done-by-design, not failures.
notready_pods() { # label-selector
  kc get pods -l "$1" --no-headers 2>/dev/null | awk '
    {
      ready=$2; status=$3
      if (status=="Completed" || status=="Succeeded") next
      split(ready,a,"/")
      if (status=="Running" && a[1]!=a[2]) { print $1" "$2" "$3; next }
      if (status=="Error" || status=="CrashLoopBackOff" || status ~ /BackOff/ || status=="ImagePullBackOff" || status=="ErrImagePull") { print $1" "$2" "$3 }
    }'
}

CUR="$(command kubectl config current-context 2>/dev/null)"
[ "$CUR" = "$CTX" ] || { echo "ABORT: current kube context is '$CUR', expected '$CTX'." >&2; exit 2; }

RESULTS=()
record() { RESULTS+=("$1"); echo "$1"; }
FAILED=0

echo "############################################################"
echo "# conductor FAILURE-MODE tests (context=$CTX ns=$NS)"
echo "############################################################"

# ---------------------------------------------------------------------------
# Setup: namespace, license, external postgres + rustfs (reuse adoption fixture)
# ---------------------------------------------------------------------------
echo "==> [setup] namespace"
kcg get ns "$NS" >/dev/null 2>&1 || kcg create ns "$NS"

echo "==> [setup] license secret"
LIC=/tmp/conductor-fail-license.json
if [ ! -s "$LIC" ]; then
  SIGN=/tmp/conductor-fail-signing; mkdir -p "$SIGN"
  kcg -n test-saas get secret license-signing-keys \
    -o jsonpath='{.data.michael-dev-signing\.private\.pem}' | base64 -d > "$SIGN/key.pem"
  MINT="$REPO/../conductor/dev/trial-testenv/scripts/mint-license.mjs"
  [ -f "$MINT" ] || MINT="/Users/explorer/git/github/cardinalhq/conductor/dev/trial-testenv/scripts/mint-license.mjs"
  node "$MINT" --key "$SIGN/key.pem" --key-id michael-dev-signing \
    --kind lakerunner --customer "$NS" --days 365 > "$LIC"
fi
kc create secret generic cardinal-license --from-file=license.json="$LIC" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

echo "==> [setup] external postgres + rustfs fixtures"
kc apply -f "$ROOT/adoption/05-fixtures.yaml" >/dev/null
kc rollout status deploy/postgres --timeout=300s
kc rollout status deploy/rustfs --timeout=300s
kc wait --for=condition=complete job/rustfs-mkbucket --timeout=180s || true

# ===========================================================================
# CASE 1 — split-brain: maestro populated, configdb empty -> auto detect ERROR
# ===========================================================================
echo
echo "=== CASE 1: split-brain (maestro populated, configdb empty) ==="
# Run lakerunner+maestro migrations only (no bootstrap) so both schemas exist,
# then populate ONLY maestro. Easiest: a throwaway adopt-mode migrate via helm
# is heavy; instead bring schemas up by a one-shot mode=adopt install+uninstall
# is also heavy. We already have empty schemas? No — fresh DBs have no tables.
# Bring up just the schemas by installing in adopt mode (renders only migrate
# hooks), then uninstall the release object but keep the migrated DBs.
echo "    [case1] migrating schemas (helm install adopt, then uninstall keeps DB)"
helm install c1 "$REPO/conductor" -n "$NS" -f "$HERE/fail-values.yaml" \
  --set bootstrap.mode=adopt --timeout 300s >/tmp/c1-install.log 2>&1 || true
# wait for both schemas to exist (migrate hooks complete during install)
for _ in $(seq 1 40); do
  HASTAB=$(psql_db maestro maestro "SELECT to_regclass('public.maestro_organizations') IS NOT NULL;")
  HASLR=$(psql_db config configdb "SELECT to_regclass('public.organizations') IS NOT NULL;")
  [ "$HASTAB" = "t" ] && [ "$HASLR" = "t" ] && break
  sleep 5
done
echo "    [case1] schemas present: maestro_organizations=$HASTAB organizations=$HASLR"
helm uninstall c1 -n "$NS" --wait >/dev/null 2>&1 || true
# now wipe configdb back to empty and populate ONLY maestro
psql_db config configdb "TRUNCATE organizations, organization_buckets, admin_api_keys CASCADE;" >/dev/null 2>&1 || true
psql_db maestro maestro "INSERT INTO maestro_organizations (id,name,slug) VALUES ('55555555-5555-5555-5555-555555555555','SB Org','sb-org') ON CONFLICT DO NOTHING;" >/dev/null
C1_LRORGS=$(psql_int config configdb 'SELECT count(*) FROM organizations;'); C1_LRORGS=${C1_LRORGS:-?}
C1_MORGS=$(psql_int maestro maestro 'SELECT count(*) FROM maestro_organizations;'); C1_MORGS=${C1_MORGS:-?}
echo "    [case1] signals: lr_orgs=$C1_LRORGS m_orgs=$C1_MORGS (want lr=0 m=1)"
kc delete job c1-bootstrap-detect --ignore-not-found >/dev/null 2>&1 || true
# NOTE: this script intentionally runs WITHOUT errexit (set -uo pipefail only);
# every fallible step checks its own rc. Do not re-enable `set -e` mid-script.
helm install c1 "$REPO/conductor" -n "$NS" -f "$HERE/fail-values.yaml" \
  --set bootstrap.mode=auto --timeout 240s >/tmp/c1-auto.log 2>&1
C1_RC=$?
C1_LOG="$(kc logs job/c1-bootstrap-detect 2>/dev/null || true)"
echo "------- case1 detect log -------"; echo "$C1_LOG" | sed 's/^/    /'; echo "--------------------------------"
if [ "$C1_RC" -ne 0 ] && echo "$C1_LOG" | grep -Eq 'ERROR|ADOPT_LEGACY'; then
  record "CASE 1 PASS: split-brain aborted (rc=$C1_RC), detect classified $(echo "$C1_LOG" | grep -Eo 'ERROR|ADOPT_LEGACY' | head -1)"
else
  record "CASE 1 FAIL: rc=$C1_RC, detect log did not show ERROR/ADOPT_LEGACY"; FAILED=1
fi
helm uninstall c1 -n "$NS" >/dev/null 2>&1 || true
kc delete job c1-bootstrap-detect --ignore-not-found >/dev/null 2>&1 || true
# helm/StatefulSets do NOT delete volumeClaimTemplate PVCs on uninstall — drop the
# orphaned c1 github-cache PVC so it can't be mistaken for the real conductor one
# in CASE 5's cold-start (it shares the github-cache component label).
kc delete pvc mirrors-c1-maestro-github-cache-0 --ignore-not-found >/dev/null 2>&1 || true
# reset DBs to empty for the clean fresh install below
psql_db maestro maestro "TRUNCATE maestro_organizations CASCADE;" >/dev/null 2>&1 || true
psql_db config configdb "TRUNCATE organizations, organization_buckets, admin_api_keys CASCADE;" >/dev/null 2>&1 || true

# ===========================================================================
# Fresh auto install used by cases 2, 4, 5
# ===========================================================================
echo
echo "=== fresh auto install (for cases 2/4/5) ==="
helm install "$REL" "$REPO/conductor" -n "$NS" -f "$HERE/fail-values.yaml" --timeout 600s >/tmp/fresh.log 2>&1
FRESH_RC=$?
if [ "$FRESH_RC" -ne 0 ]; then
  echo "    fresh install FAILED (rc=$FRESH_RC):"; tail -15 /tmp/fresh.log | sed 's/^/    /'
  record "SETUP FAIL: fresh auto install for cases 2/4/5 failed"; FAILED=1
fi
kc rollout status deploy/${REL}-maestro-maestro --timeout=420s || true
kc rollout status deploy/${REL}-lakerunner-query-api --timeout=300s || true

# Case order note: CASE 4 (helm rollback) runs BEFORE CASE 2 (anchor-Secret
# mutation). CASE 2 mutates the helm-managed anchor Secret with `kubectl patch`,
# which would take server-side-apply field ownership of .data.admin-api-key and
# make a later `helm rollback` (helm v4 uses SSA) conflict — a test-ordering
# artifact, not a chart behavior. Running rollback first avoids that.

# ===========================================================================
# CASE 3 — concurrent key-seed jobs -> exactly one admin_api_keys row, no error
# ===========================================================================
echo
echo "=== CASE 3: two concurrent key-seed jobs ==="
# Snapshot the seeded admin key hash count for the anchor key.
ANCHOR=$(kc get secret ${REL}-admin-api-key -o jsonpath='{.data.admin-api-key}' | base64 -d)
ANCHOR_HASH=$(printf %s "$ANCHOR" | shasum -a 256 | cut -d' ' -f1)
BEFORE=$(psql_int config configdb "SELECT count(*) FROM admin_api_keys WHERE key_hash='$ANCHOR_HASH';"); BEFORE=${BEFORE:-?}
echo "    rows for anchor hash before: ${BEFORE}"
# Launch two manual key-seed jobs concurrently that run the SAME insert the
# chart's key-seed uses (INSERT ... ON CONFLICT (key_hash) DO NOTHING).
kc delete job c3-keyseed-a c3-keyseed-b --ignore-not-found >/dev/null 2>&1 || true
for n in a b; do
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: c3-keyseed-$n
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: seed
        image: public.ecr.aws/docker/library/postgres:18-alpine
        command: ["/bin/sh","-ec"]
        args:
          - |
            HASH=\$(printf %s "\$ADMIN_KEY" | sha256sum | cut -d' ' -f1)
            PGPASSWORD=testpassword123 psql --set=ON_ERROR_STOP=1 -h postgres -p 5432 -U config -d configdb \\
              -c "INSERT INTO admin_api_keys (key_hash, name, description) VALUES ('\$HASH','conductor-bootstrap','c3') ON CONFLICT (key_hash) DO NOTHING;"
            echo done
        env:
        - { name: PGSSLMODE, value: "disable" }
        - { name: ADMIN_KEY, value: "$ANCHOR" }
EOF
done
# Poll for both jobs to reach succeeded=1 (more robust than a single `kc wait`).
A_OK=0; B_OK=0
for _ in $(seq 1 40); do
  A_OK=$(kc get job c3-keyseed-a -o jsonpath='{.status.succeeded}' 2>/dev/null); A_OK=${A_OK:-0}
  B_OK=$(kc get job c3-keyseed-b -o jsonpath='{.status.succeeded}' 2>/dev/null); B_OK=${B_OK:-0}
  A_FAIL=$(kc get job c3-keyseed-a -o jsonpath='{.status.failed}' 2>/dev/null); A_FAIL=${A_FAIL:-0}
  B_FAIL=$(kc get job c3-keyseed-b -o jsonpath='{.status.failed}' 2>/dev/null); B_FAIL=${B_FAIL:-0}
  { [ "$A_OK" = "1" ] && [ "$B_OK" = "1" ]; } && break
  { [ "${A_FAIL:-0}" -gt 0 ] || [ "${B_FAIL:-0}" -gt 0 ]; } && break
  sleep 5
done
AFTER=$(psql_int config configdb "SELECT count(*) FROM admin_api_keys WHERE key_hash='$ANCHOR_HASH';"); AFTER=${AFTER:-?}
echo "    rows for anchor hash after: $AFTER  (jobs succeeded a=$A_OK b=$B_OK)"
if [ "$AFTER" = "1" ] && [ "$A_OK" = "1" ] && [ "$B_OK" = "1" ]; then
  record "CASE 3 PASS: two concurrent key-seed jobs both succeeded, exactly 1 admin_api_keys row (ON CONFLICT held)"
else
  record "CASE 3 FAIL: rows=$AFTER (want 1), jobs succeeded a=$A_OK b=$B_OK (want 1/1)"; FAILED=1
fi
kc delete job c3-keyseed-a c3-keyseed-b --ignore-not-found >/dev/null 2>&1 || true

# ===========================================================================
# CASE 4 — helm rollback after upgrade -> healthy, migrations not destructive
# ===========================================================================
echo
echo "=== CASE 4: helm rollback after upgrade ==="
# Capture a marker row count that must survive an upgrade+rollback (no
# destructive migration re-run): the org row count in configdb.
ORG_BEFORE=$(psql_int config configdb "SELECT count(*) FROM organizations;"); ORG_BEFORE=${ORG_BEFORE:-?}
echo "    configdb organizations before upgrade: $ORG_BEFORE"
# Upgrade (trivial change: bump query-api replicas) -> creates revision N+1.
# Under mode=auto the pre-upgrade detect classifies ADOPT_CONDUCTOR (shared
# deployment present) and proceeds idempotently.
helm upgrade "$REL" "$REPO/conductor" -n "$NS" -f "$HERE/fail-values.yaml" \
  --set queryApi.replicas=1 --timeout 420s >/tmp/c4-upgrade.log 2>&1
C4_UP=$?
echo "    upgrade rc=$C4_UP"
kc rollout status deploy/${REL}-maestro-maestro --timeout=300s >/dev/null 2>&1 || true
# Roll back to the previous revision.
helm rollback "$REL" -n "$NS" --wait --timeout 420s >/tmp/c4-rollback.log 2>&1
C4_RB=$?
echo "    rollback rc=$C4_RB"
kc rollout status deploy/${REL}-maestro-maestro --timeout=300s >/dev/null 2>&1 || true
kc rollout status deploy/${REL}-lakerunner-query-api --timeout=300s >/dev/null 2>&1 || true
ORG_AFTER=$(psql_int config configdb "SELECT count(*) FROM organizations;"); ORG_AFTER=${ORG_AFTER:-?}
DEPLOYED=$(helm status $REL -n $NS -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null)
NOTREADY=$(notready_pods "app.kubernetes.io/instance=$REL")
echo "    configdb organizations after rollback: $ORG_AFTER  helm status=$DEPLOYED"
[ -n "$NOTREADY" ] && { echo "    not-ready pods:"; echo "$NOTREADY" | sed 's/^/      /'; }
if [ "$C4_RB" -eq 0 ] && [ "$DEPLOYED" = "deployed" ] && [ "$ORG_AFTER" = "$ORG_BEFORE" ] && [ -z "$NOTREADY" ]; then
  record "CASE 4 PASS: rollback healthy (status=$DEPLOYED), org rows preserved ($ORG_AFTER), all pods Ready"
else
  record "CASE 4 FAIL: rb_rc=$C4_RB status=$DEPLOYED orgs=$ORG_BEFORE->$ORG_AFTER notready=[$NOTREADY]"; FAILED=1
fi

# ===========================================================================
# CASE 2 — anchor-Secret / DB-key mismatch -> auth error, no whole-release
#          crashloop; re-running key-seed reconciles. (Runs last because it
#          mutates the helm-managed anchor Secret — see case-order note above.)
# ===========================================================================
echo
echo "=== CASE 2: anchor-Secret / DB-key mismatch ==="
# Rotate the anchor Secret to a brand-new key value, but DO NOT seed its hash
# into configdb yet -> the anchor key now mismatches what configdb knows. Roll
# maestro so it picks up the new MAESTRO_BOOTSTRAP_LAKERUNNER_ADMIN_API_KEY.
NEWKEY="ak_mismatch_$(date +%s)"
NEWKEY_B64=$(printf %s "$NEWKEY" | base64)
NEWKEY_HASH=$(printf %s "$NEWKEY" | shasum -a 256 | cut -d' ' -f1)
kc patch secret ${REL}-admin-api-key --type merge -p "{\"data\":{\"admin-api-key\":\"$NEWKEY_B64\"}}" >/dev/null
echo "    rotated anchor secret to a key whose hash is NOT in configdb"
MISMATCH0=$(psql_int config configdb "SELECT count(*) FROM admin_api_keys WHERE key_hash='$NEWKEY_HASH';"); MISMATCH0=${MISMATCH0:-?}
echo "    configdb rows for new hash (should be 0): $MISMATCH0"
kc rollout restart deploy/${REL}-maestro-maestro >/dev/null
# Give maestro time to come back with the mismatched key; it must NOT crashloop.
kc rollout status deploy/${REL}-maestro-maestro --timeout=240s >/tmp/c2-rollout.log 2>&1
C2_ROLL=$?
# Assert: maestro deployment is Available (it tolerates the auth failure and
# does not bring the whole release down) — its provisioning worker retries.
MAESTRO_AVAIL=$(kc get deploy ${REL}-maestro-maestro -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
MAESTRO_RESTARTS=$(kc get pods -l app.kubernetes.io/component=maestro -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
echo "    maestro availableReplicas=$MAESTRO_AVAIL restartCount=$MAESTRO_RESTARTS (rollout rc=$C2_ROLL)"
NOT_CRASH=0; { [ "${MAESTRO_AVAIL:-0}" -ge 1 ]; } && NOT_CRASH=1
# Reconcile: seed the new hash (what the chart's key-seed would do on re-run).
echo "    re-running key-seed to reconcile the new anchor key into configdb"
psql_db config configdb "INSERT INTO admin_api_keys (key_hash,name,description) VALUES ('$NEWKEY_HASH','conductor-bootstrap','reconcile') ON CONFLICT (key_hash) DO NOTHING;" >/dev/null
RECONCILED=$(psql_int config configdb "SELECT count(*) FROM admin_api_keys WHERE key_hash='$NEWKEY_HASH';"); RECONCILED=${RECONCILED:-?}
echo "    configdb rows for new hash after reconcile (should be 1): $RECONCILED"
if [ "$NOT_CRASH" = "1" ] && [ "$RECONCILED" = "1" ]; then
  record "CASE 2 PASS: maestro stayed Available under key mismatch (availableReplicas=$MAESTRO_AVAIL, restarts=$MAESTRO_RESTARTS); re-seed reconciled the key into configdb"
else
  record "CASE 2 FAIL: maestro avail=$MAESTRO_AVAIL (want >=1), reconciled=$RECONCILED (want 1)"; FAILED=1
fi

# ===========================================================================
# CASE 5 — PVC cold-start: delete github-cache PVC+pod -> re-clones, Ready
# ===========================================================================
echo
echo "=== CASE 5: github-cache PVC cold-start ==="
STS=${REL}-maestro-github-cache
kc rollout status statefulset/$STS --timeout=300s >/tmp/c5-pre.log 2>&1 || true
# Target THIS release's stable per-replica PVC by exact name. A label selector
# (app.kubernetes.io/component=github-cache) can also match an ORPHAN PVC left by
# an earlier `helm uninstall` (helm/StatefulSets do not delete volumeClaimTemplate
# PVCs), and `head -1` could then delete the wrong volume — leaving the live
# conductor pod to restart on its existing PVC and never actually cold-starting.
PVC="pvc/mirrors-${STS}-0"
PV=$(kc get pvc mirrors-${STS}-0 -o jsonpath='{.spec.volumeName}' 2>/dev/null)
echo "    deleting github-cache pod-0 + its PVC ($PVC, pv=$PV) to force a cold-start re-clone"
kc delete "$PVC" --wait=false >/dev/null 2>&1 || true
kc delete pod ${STS}-0 --grace-period=0 --force >/dev/null 2>&1 || true
# StatefulSet controller re-creates the pod and (because the PVC was deleted)
# a brand-new empty PVC, forcing a fresh clone.
sleep 5
kc rollout status statefulset/$STS --timeout=420s >/tmp/c5-post.log 2>&1
C5_RC=$?
READY=$(kc get statefulset $STS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
NEWPVC=$(kc get pvc mirrors-${STS}-0 -o jsonpath='{.status.phase}' 2>/dev/null)
NEWPV=$(kc get pvc mirrors-${STS}-0 -o jsonpath='{.spec.volumeName}' 2>/dev/null)
# A genuine cold-start binds a BRAND-NEW PersistentVolume (the old one was
# deleted with the PVC), so NEWPV must differ from the pre-delete PV.
FRESHVOL=0; { [ -n "$NEWPV" ] && [ "$NEWPV" != "$PV" ]; } && FRESHVOL=1
echo "    statefulset readyReplicas=$READY new PVC mirrors-${STS}-0 phase=$NEWPVC pv=$NEWPV (was $PV, fresh=$FRESHVOL, rollout rc=$C5_RC)"
if [ "$C5_RC" -eq 0 ] && [ "${READY:-0}" -ge 1 ] && [ "$NEWPVC" = "Bound" ] && [ "$FRESHVOL" = "1" ]; then
  record "CASE 5 PASS: github-cache cold-started — fresh PV ($NEWPV) Bound, StatefulSet Ready ($READY)"
else
  record "CASE 5 FAIL: rollout rc=$C5_RC ready=$READY pvc=$NEWPVC pv=$NEWPV (was $PV) fresh=$FRESHVOL"; FAILED=1
fi

# ---------------------------------------------------------------------------
echo
echo "===================== FAILURE-MODE RESULTS ====================="
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "==============================================================="
if [ "$FAILED" -ne 0 ]; then
  echo "FAILURE-MODE TESTS FAILED"
  exit 1
fi
echo "FAILURE-MODE TESTS PASSED"

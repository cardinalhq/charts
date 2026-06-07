#!/usr/bin/env bash
# End-to-end fresh-install test for the unified `conductor` Helm chart on kubepi.
#
# Stands up Postgres(pgvector) + rustfs in a dedicated namespace, fresh-installs
# conductor (bootstrap.mode=auto), sends logs/metrics/traces through a collector,
# and validates the data is queryable via query-api DIRECT and the maestro PROXY.
#
# SAFETY: every kubectl/helm call is pinned to --context kubepi. Aborts if the
# current kube context is anything else.
#
# Usage:  NS=conductor-fresh bash test/fresh-install/00-run.sh
# Prints `FRESH-INSTALL PASS` and exits 0 on success; leaves the install RUNNING
# for inspection (run 99-teardown.sh to clean up).
set -uo pipefail
CTX="${CTX:-kubepi}"
NS="${NS:-conductor-fresh}"
RELEASE="${RELEASE:-conductor}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../conductor}"

kc()   { command kubectl --context "$CTX" -n "$NS" "$@"; }
helm() { command helm --kube-context "$CTX" "$@"; }

# --- SAFETY: refuse to run against any context but kubepi ---
CURRENT="$(command kubectl config current-context 2>/dev/null)"
if [ "$CURRENT" != "$CTX" ]; then
  echo "ABORT: current kube context is '$CURRENT', expected '$CTX'. Refusing to run."
  exit 2
fi
[ -d "$CHART" ] || { echo "ABORT: chart not found at $CHART"; exit 2; }

echo "############################################################"
echo "# conductor FRESH-INSTALL test  (context=$CTX ns=$NS)"
echo "############################################################"

echo "==> [0] namespace"
command kubectl --context "$CTX" get ns "$NS" >/dev/null 2>&1 || command kubectl --context "$CTX" create ns "$NS"

echo "==> [1] license secret (michael-dev-signing) for both families"
# Mint a fresh license signed with the kubepi dev signing key (trusted by
# lakerunner license-go >= v0.2.1 and maestro). Reuse an existing
# license-signing-keys secret on the cluster (test-saas) so we do not embed a
# private key in the repo.
LIC=/tmp/conductor-fresh-license.json
if [ ! -s "$LIC" ]; then
  SIGN_DIR=/tmp/conductor-fresh-signing
  mkdir -p "$SIGN_DIR"
  command kubectl --context "$CTX" -n test-saas get secret license-signing-keys \
    -o jsonpath='{.data.michael-dev-signing\.private\.pem}' | base64 -d > "$SIGN_DIR/key.pem"
  MINT="$HERE/../../../conductor/dev/trial-testenv/scripts/mint-license.mjs"
  # Fall back to the canonical sibling path if the worktree-relative one misses.
  [ -f "$MINT" ] || MINT="/Users/explorer/git/github/cardinalhq/conductor/dev/trial-testenv/scripts/mint-license.mjs"
  node "$MINT" --key "$SIGN_DIR/key.pem" --key-id michael-dev-signing \
    --kind lakerunner --customer "$NS" --days 365 > "$LIC"
fi
kc create secret generic cardinal-license --from-file=license.json="$LIC" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

echo "==> [2] Postgres (pgvector) fixture"
kc apply -f "$HERE/10-postgres.yaml" >/dev/null
kc rollout status deploy/postgres --timeout=300s

echo "==> [3] rustfs S3 store + bucket"
kc apply -f "$HERE/20-rustfs.yaml" >/dev/null
kc rollout status deploy/rustfs --timeout=300s
kc wait --for=condition=complete job/rustfs-mkbucket --timeout=180s || true

echo "==> [4] helm install conductor (bootstrap.mode=auto)"
helm install "$RELEASE" "$CHART" -n "$NS" -f "$HERE/30-values.yaml" --timeout 600s

echo "==> [5] verify migrations + key-seed + maestro provisioning"
kc rollout status deploy/${RELEASE}-maestro-maestro --timeout=300s
kc rollout status deploy/${RELEASE}-lakerunner-query-api --timeout=300s
kc rollout status deploy/${RELEASE}-lakerunner-pubsub-http --timeout=300s
echo "    admin_api_keys: $(kc exec deploy/postgres -- psql -U config -d configdb -tAc "SELECT name FROM admin_api_keys;" 2>/dev/null | tr -d '[:space:]')"
echo "    maestro org:    $(kc exec deploy/postgres -- psql -U maestro -d maestro -tAc "SELECT name FROM maestro_organizations LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"

echo "==> [6] collector fixture"
kc apply -f "$HERE/40-collector.yaml" >/dev/null
kc rollout status deploy/otel-collector --timeout=300s

echo "==> [7] send telemetry (logs/metrics/traces, service.name=fresh-test)"
NS="$NS" CTX="$CTX" bash "$HERE/50-send-telemetry.sh"

echo "==> [8] validate (query-api direct + maestro proxy)"
NS="$NS" CTX="$CTX" bash "$HERE/60-validate.sh"
RC=$?

echo
if [ "$RC" -eq 0 ]; then
  echo "FRESH-INSTALL PASS"
else
  echo "FRESH-INSTALL FAIL (validation rc=$RC)"
fi
exit "$RC"

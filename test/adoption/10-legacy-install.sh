#!/usr/bin/env bash
# Task 4 step 1: install the legacy split stack (lakerunner@3.13.6 +
# maestro@0.8.22) against the EXTERNAL postgres+rustfs fixtures, with a legacy
# org provisioned in configdb via storageProfiles + apiKeys.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

echo "==> [legacy] namespace $NS"
kcg get ns "$NS" >/dev/null 2>&1 || kcg create ns "$NS"

echo "==> [legacy] license secret"
ensure_license

echo "==> [legacy] external postgres + rustfs fixtures"
kc apply -f "$HERE/05-fixtures.yaml" >/dev/null
kc rollout status deploy/postgres --timeout=300s
kc rollout status deploy/rustfs --timeout=300s
kc wait --for=condition=complete job/rustfs-mkbucket --timeout=180s || true

echo "==> [legacy] helm install lr (lakerunner 3.13.6)"
helm install lr "$ROOT/lakerunner" -n "$NS" -f "$HERE/legacy-lakerunner-values.yaml" --timeout 600s

echo "==> [legacy] helm install ms (maestro 0.8.22)"
helm install ms "$ROOT/maestro" -n "$NS" -f "$HERE/legacy-maestro-values.yaml" --timeout 600s

echo "==> [legacy] wait for setup job + rollouts"
kc wait --for=condition=complete job/lr-lakerunner-setup --timeout=300s || true
kc rollout status deploy/lr-lakerunner-query-api --timeout=300s
kc rollout status deploy/lr-lakerunner-pubsub-http --timeout=300s
kc rollout status deploy/ms-maestro-maestro --timeout=420s

echo "==> [legacy] configdb org/bucket rows (should show legacy org)"
echo "    organizations:        $(psql_db config configdb "SELECT count(*) FROM organizations;")"
echo "    organization_buckets: $(psql_db config configdb "SELECT count(*) FROM organization_buckets;")"
echo "[legacy] install complete"

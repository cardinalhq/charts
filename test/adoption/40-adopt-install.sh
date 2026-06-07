#!/usr/bin/env bash
# Task 5 step 2: helm install conductor with bootstrap.mode=adopt, pointed at the
# SAME external postgres + rustfs the legacy split charts used.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

echo "==> [adopt] helm install conductor (bootstrap.mode=adopt)"
helm install conductor "$ROOT/conductor" -n "$NS" \
  -f "$HERE/conductor-adopt-values.yaml" --timeout 600s

echo "==> [adopt] wait for rollouts"
kc rollout status deploy/conductor-maestro-maestro --timeout=420s
kc rollout status deploy/conductor-lakerunner-query-api --timeout=300s
kc rollout status deploy/conductor-lakerunner-pubsub-http --timeout=300s
echo "[adopt] install complete"

#!/usr/bin/env bash
# Task 5 step 1: uninstall the legacy split charts. The EXTERNAL postgres +
# rustfs (and all their data: configdb orgs/buckets, maestro orgs/integrations,
# the lakerunner bucket) REMAIN — that is exactly what conductor adopts.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

echo "==> [uninstall] helm uninstall lr ms"
helm uninstall lr -n "$NS" --wait || true
helm uninstall ms -n "$NS" --wait || true

echo "==> [uninstall] wait for legacy app pods to disappear (postgres/rustfs stay)"
for i in $(seq 1 60); do
  remaining="$(kc get pods -l 'app.kubernetes.io/name in (lakerunner,maestro)' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  # also catch the github-cache / mcp pods by release label
  remaining2="$(kc get pods --no-headers 2>/dev/null | grep -E '^(lr|ms)-' | wc -l | tr -d ' ')"
  if [ "$remaining2" = "0" ]; then break; fi
  sleep 5
done
echo "    leftover lr/ms pods: $(kc get pods --no-headers 2>/dev/null | grep -E '^(lr|ms)-' | wc -l | tr -d ' ')"
echo "    external stores still up:"
kc get deploy postgres rustfs --no-headers 2>/dev/null | sed 's/^/      /'

echo "==> [uninstall] confirm external DB data survived uninstall"
echo "    configdb organizations:        $(psql_db config configdb "SELECT count(*) FROM organizations;")"
echo "    configdb organization_buckets: $(psql_db config configdb "SELECT count(*) FROM organization_buckets;")"
echo "    maestro_organizations:         $(psql_db maestro maestro "SELECT count(*) FROM maestro_organizations;")"
echo "[uninstall] done"

#!/usr/bin/env bash
# Orchestrator for the conductor split->single ADOPTION test on kubepi.
#
# Proves: conductor can adopt an existing legacy split (lakerunner+maestro)
# install against an external Postgres+store with bootstrap.mode=adopt, WITHOUT
# duplicating or clobbering data; AND that mode=auto correctly ABORTS on a
# legacy-shaped DB (safety net).
#
# SAFETY: every step pins --context kubepi (via lib.sh). Aborts if the current
# context is not kubepi.
#
# Usage:  bash test/adoption/00-run.sh
# Prints `ADOPTION PASS` and exits 0 on success. On failure leaves the namespace
# up for inspection.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
export SNAP="${SNAP:-/tmp/conductor-adopt-snapshot.env}"

echo "############################################################"
echo "# conductor ADOPTION test  (context=$CTX ns=$NS)"
echo "############################################################"

bash "$HERE/10-legacy-install.sh"  || { echo "ADOPTION FAIL (10-legacy-install)"; exit 1; }
bash "$HERE/20-populate-legacy.sh" || { echo "ADOPTION FAIL (20-populate-legacy)"; exit 1; }

echo "==> [snapshot] capturing pre-adoption configdb/maestro counts -> $SNAP"
{
  echo "SNAP_ORGS=$(psql_db config configdb "SELECT count(*) FROM organizations;")"
  echo "SNAP_BUCKETS=$(psql_db config configdb "SELECT count(*) FROM organization_buckets;")"
  echo "SNAP_MORGS=$(psql_db maestro maestro "SELECT count(*) FROM maestro_organizations;")"
} > "$SNAP"
cat "$SNAP" | sed 's/^/    /'

bash "$HERE/30-uninstall-legacy.sh" || { echo "ADOPTION FAIL (30-uninstall-legacy)"; exit 1; }
bash "$HERE/40-adopt-install.sh"    || { echo "ADOPTION FAIL (40-adopt-install)"; exit 1; }
bash "$HERE/50-assert-adopt.sh"     || { echo "ADOPTION FAIL (50-assert-adopt)"; exit 1; }
bash "$HERE/60-assert-auto-aborts.sh" || { echo "ADOPTION FAIL (60-assert-auto-aborts)"; exit 1; }

echo
echo "ADOPTION PASS"

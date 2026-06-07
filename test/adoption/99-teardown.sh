#!/usr/bin/env bash
# Teardown for the adoption test: delete the throwaway namespace.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
echo "==> deleting namespace $NS"
kcg delete ns "$NS" --wait=false
echo "done (namespace deletion is async)"

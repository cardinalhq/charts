#!/usr/bin/env bash
# Shared helpers + safety for the conductor adoption test (kubepi only).
#
# SAFETY: every kubectl/helm call MUST go through kc()/helm() which pin
# --context kubepi. Sourcing this file aborts if the current kube context is
# not kubepi, so a stray default-context never touches aws-prod.
set -uo pipefail

CTX="${CTX:-kubepi}"
NS="${NS:-conductor-adopt}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# The org we provision in the legacy lakerunner (configdb) + maestro.
LEGACY_ORG="${LEGACY_ORG:-22222222-2222-2222-2222-222222222222}"
LEGACY_KEY="${LEGACY_KEY:-legacy-api-key-2222}"

kc()   { command kubectl --context "$CTX" -n "$NS" "$@"; }
kcg()  { command kubectl --context "$CTX" "$@"; }
helm() { command helm --kube-context "$CTX" "$@"; }

# psql into the bundled postgres (read or write) as a given role/db.
psql_db() { # role db sql
  kc exec -i deploy/postgres -- psql -U "$1" -d "$2" -tAc "$3"
}

_safety_check() {
  local current
  current="$(command kubectl config current-context 2>/dev/null)"
  if [ "$current" != "$CTX" ]; then
    echo "ABORT: current kube context is '$current', expected '$CTX'. Refusing to run." >&2
    exit 2
  fi
}
_safety_check

# Mint a michael-dev-signing license into secret cardinal-license in $NS.
# Reuses the same approach as the fresh-install rig.
ensure_license() {
  local lic=/tmp/conductor-adopt-license.json
  if [ ! -s "$lic" ]; then
    local sign_dir=/tmp/conductor-adopt-signing
    mkdir -p "$sign_dir"
    command kubectl --context "$CTX" -n test-saas get secret license-signing-keys \
      -o jsonpath='{.data.michael-dev-signing\.private\.pem}' | base64 -d > "$sign_dir/key.pem"
    local mint="$ROOT/../conductor/dev/trial-testenv/scripts/mint-license.mjs"
    [ -f "$mint" ] || mint="/Users/explorer/git/github/cardinalhq/conductor/dev/trial-testenv/scripts/mint-license.mjs"
    node "$mint" --key "$sign_dir/key.pem" --key-id michael-dev-signing \
      --kind lakerunner --customer "$NS" --days 365 > "$lic"
  fi
  kc create secret generic cardinal-license --from-file=license.json="$lic" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
}

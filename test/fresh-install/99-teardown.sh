#!/usr/bin/env bash
# Tear down the conductor fresh-install test: uninstall the release and delete
# the namespace (which removes Postgres/rustfs/collector and all PVCs).
#
# SAFETY: pinned to --context kubepi; aborts if the current context differs.
set -uo pipefail
CTX="${CTX:-kubepi}"
NS="${NS:-conductor-fresh}"
RELEASE="${RELEASE:-conductor}"

CURRENT="$(command kubectl config current-context 2>/dev/null)"
if [ "$CURRENT" != "$CTX" ]; then
  echo "ABORT: current kube context is '$CURRENT', expected '$CTX'. Refusing to run."
  exit 2
fi

echo "==> helm uninstall $RELEASE -n $NS"
command helm --kube-context "$CTX" uninstall "$RELEASE" -n "$NS" 2>/dev/null || true

echo "==> delete namespace $NS (removes all fixtures + PVCs)"
command kubectl --context "$CTX" delete ns "$NS" --wait=false 2>/dev/null || true

echo "teardown initiated (namespace deletion is async)"

#!/usr/bin/env bash
# Send logs + metrics + traces tagged service.name=fresh-test through the
# otel-collector fixture, which exports them to rustfs (awss3) and notifies
# pubsub-http so lakerunner ingests them.
#
# Uses telemetrygen (one-shot Jobs) over OTLP/gRPC to otel-collector:4317.
# service.name=fresh-test becomes resource_service_name=fresh-test in lakerunner,
# the marker 60-validate.sh greps for.
set -euo pipefail
CTX="${CTX:-kubepi}"
NS="${NS:-conductor-fresh}"
TGIMG="${TGIMG:-ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest}"
EP="otel-collector.${NS}.svc.cluster.local:4317"
MARKER="fresh-test"

kubectl() { command kubectl --context "$CTX" -n "$NS" "$@"; }

run_gen() {
  local signal="$1"; shift
  local job="telemetrygen-${signal}"
  echo ">> sending ${signal} (service.name=${MARKER}) to ${EP}"
  kubectl delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  labels: { app: telemetrygen }
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels: { app: telemetrygen }
    spec:
      restartPolicy: Never
      containers:
        - name: telemetrygen
          image: ${TGIMG}
          args:
$(for a in "$@"; do echo "            - '$a'"; done)
YAML
  kubectl wait --for=condition=complete "job/${job}" --timeout=120s 2>&1 || {
    echo "!! ${signal} generation did not complete; logs:"; kubectl logs "job/${job}" 2>&1 | tail -20; return 1; }
  echo "   ${signal} sent."
}

# logs: 50 log records
run_gen logs    logs    --otlp-endpoint "$EP" --otlp-insecure --service "$MARKER" --logs 50    --otlp-attributes 'test.marker="fresh-test"'
# metrics: 50 gauge data points
run_gen metrics metrics --otlp-endpoint "$EP" --otlp-insecure --service "$MARKER" --metrics 50 --otlp-attributes 'test.marker="fresh-test"'
# traces: 50 spans
run_gen traces  traces  --otlp-endpoint "$EP" --otlp-insecure --service "$MARKER" --traces 50  --otlp-attributes 'test.marker="fresh-test"'

echo ">> telemetry sent. Waiting ~90s for awss3 flush + pubsub notify + process-* ingest..."
sleep 90
echo ">> done waiting."

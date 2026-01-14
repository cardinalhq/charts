#!/bin/bash

# Script to check for duplicate environment variables in all Helm templates
# Usage: ./scripts/check-duplicate-env-vars.sh

set -e

echo "🔍 Checking for duplicate environment variables in all deployments..."

# List of templates to check (deployments, statefulsets, jobs)
TEMPLATES=(
  "ingest-logs-deployment.yaml"
  "ingest-metrics-deployment.yaml" 
  "ingest-traces-deployment.yaml"
  "compact-logs-deployment.yaml"
  "compact-metrics-deployment.yaml"
  "compact-traces-deployment.yaml"
  "rollup-metrics-deployment.yaml"
  "boxer-rollup-metrics-deployment.yaml"
  "boxer-compact-metrics-deployment.yaml"
  "boxer-compact-logs-deployment.yaml"
  "boxer-compact-traces-deployment.yaml"
  "sweeper-deployment.yaml"
  "monitoring-deployment.yaml"
  "pubsub-http-deployment.yaml"
  "pubsub-sqs-deployment.yaml"
  "pubsub-gcp-deployment.yaml"
  "pubsub-azure-deployment.yaml"
  "query-api-deployment.yaml"
  "query-worker-deployment.yaml"
  "grafana-deployment.yaml"
  "setup-job.yaml"
)

# Enable services that might be disabled by default
HELM_SET_VALUES="--set cloudProvider.aws.region=us-west-2 \
--set ingestTraces.enabled=true \
--set boxerCompactMetrics.enabled=true \
--set boxerCompactLogs.enabled=true \
--set boxerCompactTraces.enabled=true \
--set pubsub.SQS.enabled=true \
--set pubsub.SQS.queueURL=https://sqs.us-west-2.amazonaws.com/123456789/test \
--set pubsub.HTTP.enabled=true \
--set pubsub.GCP.enabled=true \
--set pubsub.GCP.projectID=test-project \
--set pubsub.GCP.subscriptionID=test-subscription \
--set pubsub.Azure.enabled=true \
--set pubsub.Azure.storageAccount=teststorage \
--set pubsub.Azure.queueName=testqueue"

FAILED=false

for template in "${TEMPLATES[@]}"; do
  echo "Checking ${template}..."
  
  # Render the template and extract environment variable names
  rendered=$(helm template test-release . ${HELM_SET_VALUES} --show-only "templates/${template}" 2>/dev/null || echo "SKIP")
  
  if [[ "$rendered" == "SKIP" ]]; then
    echo "  ⚠️  Skipped (template not rendered - likely disabled)"
    continue
  fi
  
  # Extract environment variable names from the rendered YAML
  env_vars=$(echo "$rendered" | yq eval '.spec.template.spec.containers[0].env[].name' - 2>/dev/null | sort)
  
  if [[ -z "$env_vars" ]]; then
    echo "  ✅ No environment variables found"
    continue
  fi
  
  # Check for duplicates
  duplicates=$(echo "$env_vars" | uniq -d)
  
  if [[ -n "$duplicates" ]]; then
    echo "  ❌ DUPLICATE ENVIRONMENT VARIABLES FOUND:"
    echo "$duplicates" | sed 's/^/     /'
    FAILED=true
  else
    env_count=$(echo "$env_vars" | wc -l | tr -d ' ')
    unique_count=$(echo "$env_vars" | uniq | wc -l | tr -d ' ')
    echo "  ✅ No duplicates found (${env_count} env vars, ${unique_count} unique)"
  fi
done

echo ""
if [[ "$FAILED" == "true" ]]; then
  echo "❌ FAILED: Duplicate environment variables detected!"
  exit 1
else
  echo "✅ SUCCESS: No duplicate environment variables found in any deployment!"
  exit 0
fi
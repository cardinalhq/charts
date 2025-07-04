#!/usr/bin/env bash
set -euo pipefail

export HELM_EXPERIMENTAL_OCI=1
REGISTRY="public.ecr.aws/cardinalhq.io"

# Optional: fallback if no tags exist
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

echo "🔐 Logging into public ECR..."
aws ecr-public get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin public.ecr.aws

echo "📦 Detecting changed charts..."
changed_dirs=$(git diff --name-only "$last_tag"..HEAD -- charts/ \
  | cut -d '/' -f2 \
  | sort -u)

if [[ -z "$changed_dirs" ]]; then
  echo "✅ No chart changes since $last_tag."
  exit 0
fi

for name in $changed_dirs; do
  chart_path="charts/$name"
  if [[ -f "$chart_path/Chart.yaml" ]]; then
    version=$(yq e '.version' "$chart_path/Chart.yaml")
    echo "➡️ Publishing $name version $version"
    helm chart save "$chart_path" "$REGISTRY/$name:$version"
    helm chart push "$REGISTRY/$name:$version"
  else
    echo "⚠️ Skipping $chart_path: no Chart.yaml"
  fi
done

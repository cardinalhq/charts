#!/usr/bin/env bash
set -euo pipefail

REGISTRY="public.ecr.aws/cardinalhq.io"

aws ecr-public get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin public.ecr.aws

[ -d "out" ] || mkdir out
rm -f out/*.tgz
for chart_path in *; do
  if [[ -f "$chart_path/Chart.yaml" ]]; then
    name=$(basename "$chart_path")
    version=$(yq e '.version' "$chart_path/Chart.yaml")

    helm package "$chart_path" --destination out
    helm push "out/${name}-${version}.tgz" "oci://$REGISTRY"
  fi
done

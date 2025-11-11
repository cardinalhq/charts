.PHONY: package publish help

TAG ?= latest

# Show help
help:
	@echo "CHQ K8s Watcher Helm Chart - Available targets:"
	@echo ""
	@echo "  make package          - Package the Helm chart"
	@echo "  make publish TAG=x.y.z - Package and publish chart to OCI registry"
	@echo "  make publish          - Package and publish with TAG=latest (default)"
	@echo ""
	@echo "Requirements:"
	@echo "  - TAG defaults to 'latest' if not specified"
	@echo ""

# Package the chart
package:
	@echo "Packaging Helm chart..."
	helm package .
	@echo "Chart packaged successfully"

# Publish chart to OCI registry
# Requires: helm and TAG variable
# Usage: make publish TAG=0.1.0 or just make publish (uses latest)
publish:
	@echo "Updating chart version to $(TAG)..."
	@sed -i "s/^version:.*/version: $(TAG)/" Chart.yaml
	@sed -i "s/^appVersion:.*/appVersion: \"$(TAG)\"/" Chart.yaml
	@echo "Packaging Helm chart..."
	@helm package .
	@echo "Pushing chart to OCI registry..."
	@helm push chq-k8s-watcher-$(TAG).tgz oci://public.ecr.aws/cardinalhq.io
	@echo "Chart published successfully:"
	@echo "  - oci://public.ecr.aws/cardinalhq.io/chq-k8s-watcher:$(TAG)"

.DEFAULT_GOAL := help

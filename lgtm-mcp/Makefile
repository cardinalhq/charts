.PHONY: package publish help

TAG ?=

# Show help
help:
	@echo "LGTM MCP Helm Chart - Available targets:"
	@echo ""
	@echo "  make package          - Package the Helm chart"
	@echo "  make publish TAG=x.y.z - Package and publish chart to OCI registry"
	@echo ""
	@echo "Requirements:"
	@echo "  - TAG is REQUIRED for 'make publish' (e.g., TAG=0.1.0)"
	@echo ""

# Package the chart
package:
	@echo "Packaging Helm chart..."
	helm package .
	@echo "Chart packaged successfully"

# Publish chart to OCI registry
# Requires: helm and TAG variable
# Usage: make publish TAG=0.1.0
publish:
	@if [ -z "$(TAG)" ]; then \
		echo "Error: TAG is required. Usage: make publish TAG=0.1.0"; \
		exit 1; \
	fi
	@echo "Updating chart version to $(TAG)..."
	@sed -i "s/^version:.*/version: $(TAG)/" Chart.yaml
	@echo "Packaging Helm chart..."
	@helm package .
	@echo "Pushing chart to OCI registry..."
	@helm push lgtm-mcp-$(TAG).tgz oci://public.ecr.aws/cardinalhq.io
	@echo "Chart published successfully:"
	@echo "  - oci://public.ecr.aws/cardinalhq.io/lgtm-mcp:$(TAG)"

.DEFAULT_GOAL := help

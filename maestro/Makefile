# Makefile for Maestro Helm Chart

CHART_NAME := maestro
TEST_RELEASE_NAME := test-release

.PHONY: help test check lint template clean package publish

help:  ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

test: lint template  ## Run all tests

check: test  ## Alias for test

lint:  ## Run helm lint on the chart
	@echo "Linting $(CHART_NAME) chart..."
	helm lint .

template:  ## Test template rendering
	@echo "Testing template rendering..."
	@helm template $(TEST_RELEASE_NAME) . --dry-run > /dev/null 2>&1
	@echo "Template rendering passed"

clean:  ## Clean up test artifacts and packaged charts
	@echo "Cleaning up..."
	rm -f *.tgz
	rm -rf charts/ $(OUT_DIR)/

# Chart packaging and publishing
REGISTRY := public.ecr.aws/cardinalhq.io
CHART_VERSION := $(shell yq e '.version' Chart.yaml)
OUT_DIR := packages

package:  ## Package the chart for distribution
	@echo "Packaging $(CHART_NAME) chart version $(CHART_VERSION)..."
	@mkdir -p $(OUT_DIR)
	helm package . --destination $(OUT_DIR)
	@echo "Chart packaged: $(OUT_DIR)/$(CHART_NAME)-$(CHART_VERSION).tgz"

publish: package  ## Package and publish chart to ECR registry (assumes you're already logged in)
	@echo "Publishing $(CHART_NAME) chart version $(CHART_VERSION) to $(REGISTRY)..."
	helm push "$(OUT_DIR)/$(CHART_NAME)-$(CHART_VERSION).tgz" "oci://$(REGISTRY)"
	@echo "Chart published successfully!"
	@echo "To install: helm install my-release oci://$(REGISTRY)/$(CHART_NAME) --version $(CHART_VERSION)"

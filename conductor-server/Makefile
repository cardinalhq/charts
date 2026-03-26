# Makefile for Conductor Server Helm Chart

CHART_NAME := conductor-server
TEST_RELEASE_NAME := test-release

.PHONY: help test check lint template unittest clean package publish

help:  ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

test: lint template unittest  ## Run all tests

check: test  ## Alias for test

lint:  ## Run helm lint on the chart
	@echo "Linting $(CHART_NAME) chart..."
	helm lint .

template:  ## Test template rendering with various configurations
	@helm template $(TEST_RELEASE_NAME) . --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set mcpGateway.enabled=false --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set conductorServer.enabled=false --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set maestroServer.enabled=false --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set mcpGateway.secrets.create=false --set conductorServer.secrets.create=false --set conductorServer.llmSecrets.create=false --dry-run > /dev/null 2>&1

unittest:  ## Run helm unittest tests
	@echo "Running unit tests..."
	helm unittest .

clean:  ## Clean up test artifacts and packaged charts
	@echo "Cleaning up test artifacts and packaged charts..."
	rm -f *.tgz
	rm -rf charts/ $(OUT_DIR)/

# Development helpers
template-debug:  ## Render templates and show output for debugging
	@echo "Rendering templates for debugging..."
	helm template $(TEST_RELEASE_NAME) . --debug

template-save:  ## Save rendered templates to file for inspection
	@echo "Saving rendered templates to $(CHART_NAME)-rendered.yaml..."
	helm template $(TEST_RELEASE_NAME) . > $(CHART_NAME)-rendered.yaml
	@echo "Templates saved to $(CHART_NAME)-rendered.yaml"

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

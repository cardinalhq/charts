# Makefile for griffin-commerce-demo Helm Chart Testing

CHART_NAME := griffin-commerce-demo
TEST_RELEASE_NAME := test-release

.PHONY: help test check lint template unittest clean package publish verify-icon

help:  ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

test: lint template unittest verify-icon  ## Run all tests (Layer 1 + Layer 2)

check: test  ## Alias for test - run lints and tests

lint:  ## Run helm lint on the chart
	@echo "Linting $(CHART_NAME) chart..."
	helm lint .

template:  ## Test template rendering with various configurations
	@helm template $(TEST_RELEASE_NAME) . --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set image.tag=v1.2.3 --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set ingress.enabled=false --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set ingress.host=griffin.example.com --set ingress.className=nginx --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set otel.endpoint=http://otel-collector.observability.svc.cluster.local:4318 --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set otel.useHostIp=true --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set chaos.enabled=true --dry-run > /dev/null 2>&1
	@helm template $(TEST_RELEASE_NAME) . --set chaos.enabled=true --set otel.endpoint=http://otel:4318 --dry-run > /dev/null 2>&1

unittest:  ## Run helm unittest tests
	@echo "Running unit tests..."
	@if [ -d tests ] && [ -n "$$(ls tests/*_test.yaml 2>/dev/null)" ]; then \
		helm unittest .; \
	else \
		echo "No unit tests found"; \
	fi

verify-icon:  ## Verify chart icon URL is accessible
	@echo "Verifying chart icon URL..."
	@ICON_URL=$$(yq e '.icon' Chart.yaml); \
	if [ -z "$$ICON_URL" ] || [ "$$ICON_URL" = "null" ]; then \
		echo "Warning: No icon URL defined in Chart.yaml"; \
	else \
		HTTP_CODE=$$(curl -s -o /dev/null -w "%{http_code}" --head "$$ICON_URL"); \
		if [ "$$HTTP_CODE" = "200" ]; then \
			echo "Icon URL verified: $$ICON_URL"; \
		else \
			echo "Error: Icon URL returned HTTP $$HTTP_CODE: $$ICON_URL"; \
			exit 1; \
		fi \
	fi

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

test-with-values:  ## Test with custom values file (usage: make test-with-values VALUES_FILE=my-values.yaml)
ifndef VALUES_FILE
	@echo "Please specify VALUES_FILE=<path-to-values-file>"
	@exit 1
endif
	@echo "Testing with custom values file: $(VALUES_FILE)"
	helm lint . --values $(VALUES_FILE)
	helm template $(TEST_RELEASE_NAME) . --values $(VALUES_FILE) --dry-run > /dev/null 2>&1
	@echo "Template rendering successful with $(VALUES_FILE)"

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

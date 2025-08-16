# Makefile for LakeRunner Helm Chart Testing

CHART_NAME := lakerunner
TEST_RELEASE_NAME := test-release

.PHONY: help test lint template unittest clean

help:  ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

test: lint template unittest  ## Run all tests (Layer 1 + Layer 2)

lint:  ## Run helm lint on the chart
	@echo "🔍 Linting $(CHART_NAME) chart..."
	helm lint .

template:  ## Test template rendering with various configurations
	@echo "🎨 Testing template rendering..."
	@echo "  → Default configuration"
	helm template $(TEST_RELEASE_NAME) . --debug --dry-run > /dev/null
	@echo "  → With global tag override"
	helm template $(TEST_RELEASE_NAME) . --set global.image.tag=v1.2.3 --debug --dry-run > /dev/null
	@echo "  → With disabled components"
	helm template $(TEST_RELEASE_NAME) . --set queryApi.enabled=false --set grafana.enabled=false --debug --dry-run > /dev/null
	@echo "  → With air-gapped Grafana plugin"
	helm template $(TEST_RELEASE_NAME) . --set grafana.cardinalPlugin.url="https://internal.example.com/plugin.zip;cardinalhq-lakerunner-datasource" --debug --dry-run > /dev/null
	@echo "  → With additional Grafana plugins"
	helm template $(TEST_RELEASE_NAME) . --set grafana.additionalPlugins="grafana-clock-panel" --debug --dry-run > /dev/null
	@echo "  → With custom scaling"
	helm template $(TEST_RELEASE_NAME) . --set queryApi.replicas=3 --set ingestLogs.replicas=5 --debug --dry-run > /dev/null

unittest:  ## Run helm unittest tests
	@echo "🧪 Running unit tests..."
	helm unittest .

clean:  ## Clean up test artifacts
	@echo "🧹 Cleaning up test artifacts..."
	rm -f *.tgz
	rm -rf charts/

# Development helpers
template-debug:  ## Render templates and show output for debugging
	@echo "🔍 Rendering templates for debugging..."
	helm template $(TEST_RELEASE_NAME) . --debug

template-save:  ## Save rendered templates to file for inspection
	@echo "💾 Saving rendered templates to $(CHART_NAME)-rendered.yaml..."
	helm template $(TEST_RELEASE_NAME) . > $(CHART_NAME)-rendered.yaml
	@echo "Templates saved to $(CHART_NAME)-rendered.yaml"

test-with-values:  ## Test with custom values file (usage: make test-with-values VALUES_FILE=my-values.yaml)
ifndef VALUES_FILE
	@echo "❌ Please specify VALUES_FILE=<path-to-values-file>"
	@exit 1
endif
	@echo "🎨 Testing with custom values file: $(VALUES_FILE)"
	helm lint . --values $(VALUES_FILE)
	helm template $(TEST_RELEASE_NAME) . --values $(VALUES_FILE) --debug --dry-run > /dev/null
	@echo "✅ Template rendering successful with $(VALUES_FILE)"
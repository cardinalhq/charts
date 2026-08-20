# Makefile for the unified Conductor chart.
# Default values alone don't render (bootstrap.org.id et al are required), so
# every target renders against the shared test fixture.

CHART_NAME := conductor
TEST_RELEASE_NAME := test-release
VALUES := tests/values-unified.yaml

.PHONY: help test check lint template unittest clean

help:  ## Show this help message
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

test: lint template unittest  ## Run all tests

check: test  ## Alias for test

lint:  ## Run helm lint on the chart
	@echo "Linting $(CHART_NAME) chart..."
	helm lint . --values $(VALUES)

template:  ## Test template rendering
	@echo "Testing template rendering..."
	@helm template $(TEST_RELEASE_NAME) . --values $(VALUES) > /dev/null
	@helm template $(TEST_RELEASE_NAME) . --values $(VALUES) --set bootstrap.mode=adopt > /dev/null
	@echo "Template rendering passed"

unittest:  ## Run helm unittest tests
	@echo "Running unit tests..."
	helm unittest . -v $(VALUES)

clean:  ## Clean up test artifacts and packaged charts
	rm -f *.tgz
	rm -rf charts/

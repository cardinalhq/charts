# Top-level Makefile for CardinalHQ Helm Charts Repository
# This Makefile can test multiple charts and scales as the repository grows

# Discover all charts by looking for Chart.yaml files
CHARTS := $(patsubst %/Chart.yaml,%,$(wildcard */Chart.yaml))
CHART_DIRS := $(CHARTS)

# Default test release name
TEST_RELEASE_NAME := test-release

# Colors for output
GREEN := \033[32m
RED := \033[31m
YELLOW := \033[33m
CYAN := \033[36m
RESET := \033[0m

.PHONY: help test check lint template unittest clean list-charts test-chart package publish

help:  ## Show this help message
	@echo "$(CYAN)CardinalHQ Helm Charts Testing$(RESET)"
	@echo ""
	@echo "$(YELLOW)Available charts:$(RESET)"
	@for chart in $(CHARTS); do echo "  - $$chart"; done
	@echo ""
	@echo "$(YELLOW)Available targets:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(YELLOW)Examples:$(RESET)"
	@echo "  make test                    # Test all charts"
	@echo "  make test-chart CHART=lakerunner  # Test specific chart"
	@echo "  make lint                    # Lint all charts"
	@echo "  make unittest CHART=lakerunner    # Run unit tests for specific chart"

list-charts:  ## List all discovered charts
	@echo "$(CYAN)Discovered charts:$(RESET)"
	@for chart in $(CHARTS); do echo "  $(GREEN)*$(RESET) $$chart"; done

test: lint template unittest  ## Run all tests for all charts (Layer 1 + Layer 2)
	@echo "$(GREEN)All tests completed successfully!$(RESET)"

check: test  ## Alias for test - run lints and tests for all charts

lint:  ## Run helm lint on all charts
	@echo "$(CYAN)Linting all charts...$(RESET)"
	@failed_charts=""; \
	for chart in $(CHARTS); do \
		echo "$(YELLOW)  → Linting $$chart$(RESET)"; \
		if [ -f "$$chart/Makefile" ]; then \
			if ! $(MAKE) -C $$chart lint; then \
				echo "$(RED)Lint failed for $$chart$(RESET)"; \
				failed_charts="$$failed_charts $$chart"; \
			else \
				echo "$(GREEN)Lint passed for $$chart$(RESET)"; \
			fi; \
		else \
			if ! helm lint $$chart; then \
				echo "$(RED)Lint failed for $$chart$(RESET)"; \
				failed_charts="$$failed_charts $$chart"; \
			else \
				echo "$(GREEN)Lint passed for $$chart$(RESET)"; \
			fi; \
		fi; \
	done; \
	if [ -n "$$failed_charts" ]; then \
		echo "$(RED)Lint failed for charts:$$failed_charts$(RESET)"; \
		exit 1; \
	fi

template:  ## Test template rendering for all charts
	@echo "$(CYAN)Testing template rendering for all charts...$(RESET)"
	@failed_charts=""; \
	for chart in $(CHARTS); do \
		echo "$(YELLOW)  → Testing template rendering for $$chart$(RESET)"; \
		if [ -f "$$chart/Makefile" ]; then \
			if ! $(MAKE) -C $$chart template; then \
				echo "$(RED)Template rendering failed for $$chart$(RESET)"; \
				failed_charts="$$failed_charts $$chart"; \
			else \
				echo "$(GREEN)Template rendering passed for $$chart$(RESET)"; \
			fi; \
		else \
			echo "$(YELLOW)No Makefile found for $$chart, running basic template test$(RESET)"; \
			if ! helm template $(TEST_RELEASE_NAME) $$chart --dry-run > /dev/null 2>&1; then \
				echo "$(RED)Basic template rendering failed for $$chart$(RESET)"; \
				failed_charts="$$failed_charts $$chart"; \
			else \
				echo "$(GREEN)Basic template rendering passed for $$chart$(RESET)"; \
			fi; \
		fi; \
	done; \
	if [ -n "$$failed_charts" ]; then \
		echo "$(RED)Template rendering failed for charts:$$failed_charts$(RESET)"; \
		exit 1; \
	fi

unittest:  ## Run helm unittest for all charts
	@echo "$(CYAN)Running unit tests for all charts...$(RESET)"
	@failed_charts=""; \
	for chart in $(CHARTS); do \
		echo "$(YELLOW)  → Running unit tests for $$chart$(RESET)"; \
		if [ -d "$$chart/tests" ] && [ -n "$$(ls $$chart/tests/*_test.yaml 2>/dev/null)" ]; then \
			if [ -f "$$chart/Makefile" ]; then \
				if ! $(MAKE) -C $$chart unittest; then \
					echo "$(RED)Unit tests failed for $$chart$(RESET)"; \
					failed_charts="$$failed_charts $$chart"; \
				else \
					echo "$(GREEN)Unit tests passed for $$chart$(RESET)"; \
				fi; \
			else \
				if ! helm unittest $$chart; then \
					echo "$(RED)Unit tests failed for $$chart$(RESET)"; \
					failed_charts="$$failed_charts $$chart"; \
				else \
					echo "$(GREEN)Unit tests passed for $$chart$(RESET)"; \
				fi; \
			fi; \
		else \
			echo "$(YELLOW)No unit tests found for $$chart (no tests/*_test.yaml files)$(RESET)"; \
		fi; \
	done; \
	if [ -n "$$failed_charts" ]; then \
		echo "$(RED)Unit tests failed for charts:$$failed_charts$(RESET)"; \
		exit 1; \
	fi

test-chart:  ## Test a specific chart (usage: make test-chart CHART=lakerunner)
ifndef CHART
	@echo "$(RED)Please specify CHART=<chart-name>$(RESET)"
	@echo "Available charts: $(CHARTS)"
	@exit 1
endif
	@if [ ! -d "$(CHART)" ]; then \
		echo "$(RED)Chart '$(CHART)' not found$(RESET)"; \
		echo "Available charts: $(CHARTS)"; \
		exit 1; \
	fi
	@echo "$(CYAN)Testing chart: $(CHART)$(RESET)"
	@if [ -f "$(CHART)/Makefile" ]; then \
		$(MAKE) -C $(CHART) test; \
	else \
		echo "$(YELLOW)No Makefile found for $(CHART), running basic tests$(RESET)"; \
		helm lint $(CHART); \
		helm template $(TEST_RELEASE_NAME) $(CHART) --dry-run > /dev/null 2>&1; \
		if [ -d "$(CHART)/tests" ]; then helm unittest $(CHART); fi; \
	fi
	@echo "$(GREEN)Tests completed for $(CHART)$(RESET)"

clean:  ## Clean up test artifacts for all charts
	@echo "$(CYAN)Cleaning up test artifacts...$(RESET)"
	@for chart in $(CHARTS); do \
		echo "$(YELLOW)  → Cleaning $$chart$(RESET)"; \
		if [ -f "$$chart/Makefile" ]; then \
			$(MAKE) -C $$chart clean 2>/dev/null || true; \
		fi; \
		rm -f $$chart/*.tgz; \
		rm -rf $$chart/charts/; \
	done
	@echo "$(GREEN)Cleanup completed$(RESET)"

# Package all charts
package:  ## Package all charts
	@echo "$(CYAN)Packaging all charts...$(RESET)"
	@mkdir -p packages
	@for chart in $(CHARTS); do \
		echo "$(YELLOW)  → Packaging $$chart$(RESET)"; \
		helm package $$chart --destination packages; \
	done
	@echo "$(GREEN)All charts packaged in packages/ directory$(RESET)"

publish: package  ## Package and publish all charts to ECR registry (assumes you're already logged in)
	@echo "$(CYAN)Publishing all charts to ECR registry...$(RESET)"
	@REGISTRY="public.ecr.aws/cardinalhq.io"; \
	for chart in $(CHARTS); do \
		echo "$(YELLOW)  → Publishing $$chart$(RESET)"; \
		CHART_VERSION=$$(yq e '.version' $$chart/Chart.yaml); \
		helm push "packages/$$chart-$$CHART_VERSION.tgz" "oci://$$REGISTRY"; \
		echo "$(GREEN)    $$chart version $$CHART_VERSION published$(RESET)"; \
	done
	@echo "$(GREEN)All charts published successfully!$(RESET)"

# Dependency management
deps:  ## Update dependencies for all charts
	@echo "$(CYAN)Updating dependencies for all charts...$(RESET)"
	@for chart in $(CHARTS); do \
		if [ -f "$$chart/Chart.yaml" ] && grep -q "^dependencies:" $$chart/Chart.yaml 2>/dev/null; then \
			echo "$(YELLOW)  → Updating dependencies for $$chart$(RESET)"; \
			helm dependency update $$chart; \
		else \
			echo "$(YELLOW)  → No dependencies found for $$chart$(RESET)"; \
		fi; \
	done

# Chart-specific targets that delegate to individual chart Makefiles
lint-chart unittest-chart template-chart:  ## Run specific test for a chart (usage: make lint-chart CHART=lakerunner)
ifndef CHART
	@echo "$(RED)Please specify CHART=<chart-name>$(RESET)"
	@exit 1
endif
	@target=$$(echo $@ | sed 's/-chart$$//'); \
	if [ -f "$(CHART)/Makefile" ]; then \
		$(MAKE) -C $(CHART) $$target; \
	else \
		echo "$(RED)No Makefile found for $(CHART)$(RESET)"; \
		exit 1; \
	fi

# CI/CD integration
ci:  ## Run tests suitable for CI/CD (no colors, structured output)
	@echo "Running CI tests for all charts..."
	@failed_charts=""; \
	total_charts=0; \
	passed_charts=0; \
	for chart in $(CHARTS); do \
		total_charts=$$((total_charts + 1)); \
		echo "Testing chart: $$chart"; \
		if [ -f "$$chart/Makefile" ]; then \
			if $(MAKE) -C $$chart test > /dev/null 2>&1; then \
				echo "  PASS: $$chart"; \
				passed_charts=$$((passed_charts + 1)); \
			else \
				echo "  FAIL: $$chart"; \
				failed_charts="$$failed_charts $$chart"; \
			fi; \
		else \
			if helm lint $$chart > /dev/null 2>&1 && \
			   helm template $(TEST_RELEASE_NAME) $$chart --dry-run > /dev/null 2>&1 && \
			   ([ ! -d "$$chart/tests" ] || helm unittest $$chart > /dev/null 2>&1); then \
				echo "  PASS: $$chart"; \
				passed_charts=$$((passed_charts + 1)); \
			else \
				echo "  FAIL: $$chart"; \
				failed_charts="$$failed_charts $$chart"; \
			fi; \
		fi; \
	done; \
	echo "Results: $$passed_charts/$$total_charts charts passed"; \
	if [ -n "$$failed_charts" ]; then \
		echo "Failed charts:$$failed_charts"; \
		exit 1; \
	fi

# Development helpers
watch:  ## Watch for changes and run tests (requires entr)
	@echo "$(CYAN)Watching for changes (requires 'entr' command)...$(RESET)"
	@if ! command -v entr > /dev/null; then \
		echo "$(RED)'entr' command not found. Install with: brew install entr$(RESET)"; \
		exit 1; \
	fi
	@find $(CHARTS) -name "*.yaml" -o -name "*.tpl" | entr -c make test

# Show chart information
info:  ## Show information about all charts
	@echo "$(CYAN)Chart Information$(RESET)"
	@for chart in $(CHARTS); do \
		echo ""; \
		echo "$(YELLOW)Chart: $$chart$(RESET)"; \
		if [ -f "$$chart/Chart.yaml" ]; then \
			version=$$(grep "^version:" $$chart/Chart.yaml | awk '{print $$2}'); \
			appVersion=$$(grep "^appVersion:" $$chart/Chart.yaml | awk '{print $$2}' | tr -d '"'); \
			description=$$(grep "^description:" $$chart/Chart.yaml | cut -d' ' -f2-); \
			echo "  Version: $$version"; \
			echo "  App Version: $$appVersion"; \
			echo "  Description: $$description"; \
			if [ -d "$$chart/tests" ]; then \
				test_files=$$(ls $$chart/tests/*_test.yaml 2>/dev/null | wc -l | tr -d ' '); \
				echo "  Test Files: $$test_files"; \
			else \
				echo "  Test Files: 0"; \
			fi; \
		fi; \
	done
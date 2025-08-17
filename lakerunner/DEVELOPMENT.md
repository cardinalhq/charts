# Development and Testing

## Local Development

The chart includes a comprehensive Makefile for local development and testing:

```bash
# Run all tests (lint, template rendering, unit tests)
make test

# Individual test types
make lint          # Helm lint validation
make template      # Template rendering tests with various configurations
make unittest      # Helm unittest execution

# Debugging and inspection
make template-debug              # Render templates with debug output
make template-save              # Save rendered templates to file
make test-with-values VALUES_FILE=my-values.yaml  # Test with custom values

# Chart packaging and publishing
make package       # Package chart for distribution
make publish       # Package and publish to ECR registry (requires login)
```

## Chart Packaging

Charts can be packaged locally and published to the ECR registry:

```bash
# Package to packages/ directory
make package

# Publish to public.ecr.aws/cardinalhq.io (assumes ECR login)
make publish
```

The chart version is automatically extracted from `Chart.yaml` during packaging and publishing.

## Contributing

When making changes to the chart:

1. Update tests as needed in the `tests/` directory
2. Run `make test` to ensure all tests pass
3. Update documentation if configuration options change
4. Test with both HPA and KEDA scaling modes
5. Verify backward compatibility for existing configurations

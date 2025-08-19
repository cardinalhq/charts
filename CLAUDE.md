# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Helm charts repository for CardinalHQ products, specifically containing the `lakerunner` chart. LakeRunner is a log and metrics processing platform that ingests data from S3 object stores and processes it for querying.

## Chart Management Commands

### Release Management

The chart follows an RC-first release strategy where all releases must go through a Release Candidate (RC) phase for testing before promotion to a stable release.

#### Build RC Version
```bash
# Build next RC version automatically (e.g., 0.4.1-rc1)
make build-rc VERSION=0.4.1

# Build specific RC number
make build-rc VERSION=0.4.1 RC=2

# Alternative: Use the script directly
./.github/scripts/rc-manager.sh build-rc 0.4.1
```

#### Promote RC to Release
```bash
# After testing passes, promote RC to stable release
make promote-rc RC=0.4.1-rc1

# Alternative: Use the script directly
./.github/scripts/rc-manager.sh promote-rc 0.4.1-rc1
```

#### Release Status and Management
```bash
# Show current chart status and recent versions
make rc-status

# List all available RC and release versions
make rc-list

# Monitor GitHub Actions progress
gh run list --workflow=build-rc.yml
gh run list --workflow=promote-rc.yml
```

#### Manual Package and Publish (Legacy)
```bash
# Package a chart
helm package lakerunner --destination out

# Login to ECR registry (requires AWS credentials)
aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws

# Push chart to registry
helm push "out/lakerunner-<version>.tgz" "oci://public.ecr.aws/cardinalhq.io"
```

### Chart Development
```bash
# Validate chart syntax
helm lint lakerunner

# Test template rendering
helm template test-release lakerunner --values lakerunner/values.yaml

# Dry run installation
helm install test-release lakerunner --dry-run --debug --values values-local.yaml
```

## Architecture

The LakeRunner chart deploys a comprehensive data processing pipeline with these main components:

### Data Ingestion Layer
- **ingest-logs**: Processes log data from S3 notifications
- **ingest-metrics**: Processes metrics data from S3 notifications 
- **pubsub-http**: HTTP-based notification receiver for non-AWS S3 systems
- **pubsub-sqs**: SQS-based notification receiver for AWS S3

### Data Processing Layer
- **compact-logs**: Compacts and optimizes log data storage
- **compact-metrics**: Compacts and optimizes metrics data storage
- **rollup-metrics**: Aggregates metrics at different time intervals
- **sweeper**: Cleanup and maintenance tasks

### Query Layer
- **query-api**: API service for querying stored data (StatefulSet for persistent storage)
- **query-worker**: Background workers for query processing
- **grafana**: Visualization and dashboard service

### Infrastructure
- **setup-job**: One-time setup and initialization tasks
- PostgreSQL database integration for metadata storage
- S3-compatible object storage for data persistence

## Key Configuration Areas

### Storage Profiles
Defines mapping between S3 buckets and organization/collector instances. Required even for single-tenant deployments.

### API Keys  
Organization-scoped authentication for query API access.

### Secrets Management
The chart uses Kubernetes secrets for:
- Database credentials (`postgresql-secret.yaml`)
- AWS credentials (`aws-credentials-secret.yaml`) 
- API keys (`apikeys-secret.yaml`)
- Inter-service tokens (`token-secret.yaml`)

### Scaling Configuration
Most services support HPA (Horizontal Pod Autoscaling) and have configurable resource limits. Key scaling points:
- Ingest services scale based on S3 notification volume
- Query services scale based on API usage
- Processing services scale based on data volume

## Template Structure

Templates follow standard Helm patterns:
- `_helpers.tpl`: Common template functions and labels
- Component-specific deployments/statefulsets
- Services, HPAs, and configuration resources
- RBAC resources (ServiceAccount, Role)

The chart uses a comprehensive labeling strategy with both standard Kubernetes labels and CardinalHQ-specific labels (`lakerunner.cardinalhq.io/*`).
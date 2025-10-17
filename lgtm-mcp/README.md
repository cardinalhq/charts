# LGTM MCP Helm Chart

Unified Helm chart for deploying LGTM (Loki, Grafana, Tempo, Mimir) MCP servers to Kubernetes.

## Features

- **Conditional Service Deployment**: Enable/disable individual MCP servers (Loki, Tempo)
- **Shared Cardinal API Key**: Single API key configuration for all services
- **Multi-Tenant Support**: Configure single or multiple tenants with custom headers per tenant
- **Flexible Configuration**: Per-service image, resources, and tenant configuration
- **Security-First**: Non-root containers, read-only filesystems, dropped capabilities
- **OCI Registry**: Published to `public.ecr.aws/cardinalhq.io/lgtm-charts`

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- CardinalHQ API key

## Installation

### From OCI Registry

```bash
helm install lgtm oci://public.ecr.aws/cardinalhq.io/lgtm-charts/lgtm-mcp --version 1.1.0 -f /path/to/values.yaml
```

### From Source

```bash
cd charts/lgtm-mcp
helm install lgtm . -f /path/to/values.yaml
```

## Configuration

### Loki MCP Server

#### Single-Tenant Configuration

For single-tenant Loki deployments (with `auth_enabled: false`):

```yaml
loki:
  enabled: true
  image:
    repository: public.ecr.aws/cardinalhq.io/loki-mcp
    tag: "v1.3.0"
  url: "http://loki.monitoring:3100"
  tenants:
    default: {}  # No headers needed for auth_enabled: false
```

For single-tenant Loki with multi tenancy (with `auth_enabled: true`):

```yaml
loki:
  enabled: true
  url: "http://loki.monitoring:3100"
  tenants:
    default:
      X-Scope-OrgID: "my-org"
```

#### Multi-Tenant Configuration

For multi-tenant Loki deployments, configure multiple tenants with their respective headers:

```yaml
loki:
  enabled: true
  url: "http://loki.monitoring:3100"
  tenants:
    prod:
      X-Scope-OrgID: "prod"
    staging:
      X-Scope-OrgID: "staging"
    dev:
      X-Scope-OrgID: "dev"
      Authorization: "Bearer custom-token"  # Arbitrary headers supported
```

Each tenant can have arbitrary HTTP headers. The MCP server will query all configured tenants in parallel and aggregate results.

### Tempo MCP Server

```yaml
tempo:
  enabled: true
  image:
    repository: public.ecr.aws/cardinalhq.io/tempo-mcp
    tag: "v0.1.0"
  url: "http://tempo.tempo:3200"
  headers:
    X-Scope-OrgID: "prod"
```

### Cardinal API Key

```yaml
cardinal:
  apiKey: "your-api-key-here"
  secret:
    name: cardinal-api-key
    create: true
```

## Publishing

To publish a new version:

```bash
cd charts/lgtm-mcp
make publish VERSION=0.1.0
```

## Values

See [values.yaml](values.yaml) for full configuration options.

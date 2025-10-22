# LGTM MCP Helm Chart

Unified Helm chart for deploying CardinalHQ Loki and Tempo MCP servers to Kubernetes.


## Prerequisites

- Kubernetes 
- Helm
- CardinalHQ API key

## Installation

### From OCI Registry

```bash
helm install lgtm oci://public.ecr.aws/cardinalhq.io/lgtm-mcp --version 1.6.0 -f /path/to/values.yaml
```

### From Source

```bash
cd charts/lgtm-mcp
helm install lgtm . -f /path/to/values.yaml
```

## Configuration

### Loki MCP Server

**Note:** If you don't specify `loki.tenants`, a default single-tenant configuration with no headers is automatically created (suitable for Loki with `auth_enabled: false`).

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
    my-org:
      X-Scope-OrgID: "my-org"
```

For multi-tenant Loki deployments:

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

**Note:** If you don't specify `tempo.tenants`, a default single-tenant configuration with no headers is automatically created (suitable for Tempo with `multi_tenancy: false`).

For single-tenant Tempo deployments (with `multi_tenancy: false`):

```yaml
tempo:
  enabled: true
  image:
    repository: public.ecr.aws/cardinalhq.io/tempo-mcp
    tag: "v0.2.0"
  url: "http://tempo.tempo:3200"
  tenants:
    my-org: {}  # No headers needed for multi_tenancy: false
```

For single-tenant Tempo with multi tenancy (with `multi_tenancy: true`):

```yaml
tempo:
  enabled: true
  url: "http://tempo.tempo:3200"
  tenants:
    my-org:
      X-Scope-OrgID: "my-org"
```

For multi-tenant Tempo deployments:

```yaml
tempo:
  enabled: true
  url: "http://tempo.tempo:3200"
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

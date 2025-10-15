# LGTM MCP Helm Chart

Unified Helm chart for deploying LGTM (Loki, Grafana, Tempo, Mimir) MCP servers to Kubernetes.

## Features

- **Conditional Service Deployment**: Enable/disable individual MCP servers (Loki, Tempo)
- **Shared Cardinal API Key**: Single API key configuration for all services
- **Flexible Configuration**: Per-service image, resources, and headers configuration
- **Security-First**: Non-root containers, read-only filesystems, dropped capabilities
- **OCI Registry**: Published to `public.ecr.aws/cardinalhq.io/lgtm-charts`

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- CardinalHQ API key

## Installation

### From OCI Registry

```bash
helm install lgtm oci://public.ecr.aws/cardinalhq.io/lgtm-charts/lgtm-mcp \
  --version 0.1.0 \
  --set cardinal.apiKey=<your-api-key> \
  --set loki.url=http://loki.monitoring:3100 \
  --set tempo.url=http://tempo.tempo:3200
```

### From Source

```bash
cd charts/lgtm-mcp
helm install lgtm . \
  --set cardinal.apiKey=<your-api-key> \
  --set loki.url=http://loki.monitoring:3100 \
  --set tempo.url=http://tempo.tempo:3200
```

## Configuration

### Loki MCP Server

```yaml
loki:
  enabled: true
  image:
    repository: public.ecr.aws/cardinalhq.io/loki-mcp
    tag: "v0.2.0"
  url: "http://loki.monitoring:3100"
  headers:
    X-Scope-OrgID: "tenant1"
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
```

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
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
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

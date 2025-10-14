# Loki MCP Helm Chart

Helm chart for deploying Loki MCP Server to Kubernetes.

## Installation

```bash
helm install loki-mcp oci://public.ecr.aws/cardinalhq.io/loki-mcp \
  --set loki.address=<loki-address> \
  --set cardinal.apiKey=<your-api-key>
```

## Configuration

Required values:
- `loki.address` - Loki server address (e.g., `loki.monitoring:3100`)
- `cardinal.apiKey` - CardinalHQ API key

Optional values:
- `loki.useHttps` - Use HTTPS for Loki (default: `false`)
- `lakerunner.apiHost` - Lakerunner API host for query validation
- `image.tag` - Override image version (defaults to chart `appVersion`)

## Example

```bash
helm install loki-mcp oci://public.ecr.aws/cardinalhq.io/loki-mcp \
  --set loki.address=loki.monitoring.svc.cluster.local:3100 \
  --set cardinal.apiKey=your-key-here \
  --set lakerunner.apiHost=app.cardinalhq.io
```

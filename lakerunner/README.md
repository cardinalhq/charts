# Lakerunner

## Requirements

* A Kubernetes cluster running a modern version of Kubernetes, at least 1.28.
* A PostgreSQL database, at least version 16.
* An S3 (or compatible) object store configured to send object create notifications either via SQS or a web hook.
* (Optional but **recommended for production use**) [KEDA](https://keda.sh/) installed in your cluster for intelligent autoscaling.

For AWS S3, SQS queues for bucket notifications should be used.  Other systems may have
other mechanisms, and a webhook-style receiver can be enabled to support them.

## Installation

Create a `values-local.yaml` file (see below) and run:

```sh
helm install lakerunner oci://public.ecr.aws/cardinalhq.io/lakerunner \
   --version 0.7.2 \
   --values values-local.yaml \
   --namespace lakerunner --create-namespace
```

## `value-local.yaml`

The [default `values.yaml`](https://github.com/cardinalhq/charts/blob/main/lakerunner/values.yaml) file has several settings you will need to provide.

* AWS credentials, which are required to be in a secret (for now), either in the values file or an existing secret name to get them from.
* PostgreSQL connection details
* PostgreSQL password, or a secret to get it from.
* Storage Profiles
* API Keys
* Inter-process token, randomly generated.
* If using a non-AWS S3, select the webhook-style pubsub receiver and disable the SQS one.

Items you may want to change, but are not required:

* Scaling setup.
* Memory and CPU limits.

The settings in the values.yaml file are suitable for a small to medium installation,
but for a very small or larger installation, you will need to make adjustments.

## KEDA Autoscaling

LakeRunner supports intelligent work queue-based autoscaling through [KEDA](https://keda.sh/). KEDA is **highly recommended for production environments** as it provides superior scaling behavior compared to CPU-based HPA for micro-batch workloads.

### Installing KEDA

If KEDA is not already installed in your cluster, install it:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda-system --create-namespace
```

### Enabling KEDA Scaling

To enable KEDA-based scaling in LakeRunner:

```yaml
global:
  autoscaling:
    mode: "keda"
```

### Scaling Modes

LakeRunner supports three scaling modes:

* **`hpa`** (default): CPU-based horizontal pod autoscaling. Suitable for development but insufficient for production micro-batch workloads.
* **`keda`**: Work queue-based scaling using PostgreSQL queries. **Recommended for production** as it scales based on actual workload backlog.
* **`disabled`**: No autoscaling; uses static replica counts.

You can set a global scaling mode and disable it for individual components:

```yaml
global:
  autoscaling:
    mode: "keda"

ingestLogs:
  autoscaling:
    enabled: false  # Disable autoscaling for this component only
```

### How KEDA Scaling Works

KEDA scales components based on actual workload backlog rather than CPU usage:

* **Queue-based scaling**: Components scale up when work is pending, scale down when idle
* **Intelligent thresholds**: Pre-configured to prevent over-scaling while ensuring responsiveness
* **Cooldown periods**: Prevent scaling flapping during batch processing cycles

### KEDA Configuration

Each scalable component supports KEDA configuration:

```yaml
ingestLogs:
  autoscaling:
    minReplicas: 1         # Used by both HPA and KEDA
    maxReplicas: 10        # Used by both HPA and KEDA
    keda:
      pollingInterval: 30    # How often to check queue (seconds)
      cooldownPeriod: 300    # Wait before scaling down (seconds)
```

KEDA scaling thresholds are pre-configured with sensible defaults but can be customized if needed.

### KEDA Database Integration

KEDA automatically uses the same database credentials configured in the `database.lrdb` section - no additional configuration is required. When you enable KEDA mode, it will:

* Use the same PostgreSQL connection details as your LakeRunner components
* Automatically create the necessary TriggerAuthentication resource
* Scale based on the actual work queue depth in your database

Simply ensure your database configuration is complete:

```yaml
database:
  lrdb:
    host: "your-postgres-host"      # Required
    port: 5432                      # Default: 5432
    name: "lakerunner"             # Default: "lakerunner"
    username: "lakerunner"         # Default: "lakerunner"
    password: "your-password"      # Required if not from a pre-defined secret
```

## Security Context and Distroless Compatibility

LakeRunner containers run as a non-root user and drop all capabilities.

### Grafana Component

Grafana continues to use its standard configuration:

* **User ID**: 472 (standard Grafana user)
* **Group ID**: 472
* **FSGroup**: 472

## Secrets

Secrets are used for all credentials.  They can be provided in the values files (not recommended) or
created and their names provided in the values file.  If the secret names are provided, the name of
the secret is the name provided in values, and if it is not provided (`create` is set to `true` for that
secret) it will be prefixed with the release name.

## Storage Profiles

Storage Profiles are used to map from an incoming bucket notification to the organization
and collector instance.  Even if you only have a single bucket, one collector, and one
organization, you need to define a profile.

Storage profiles are defined in YAML, via the values file:

```yaml
storageProfiles:
  yaml: []
    - organization_id: dddddddd-aaaa-4ff9-ae8f-365873c552f0
      instance_num: 1
      collector_name: "kubepi"
      cloud_provider: "aws"
      region: "us-east-2"
      bucket: "datalake-11ndajkhk"
      use_path_style: true
```

The organization_id is arbitrary, but must be a UUID.
`instance_num` should be unique within the same organization, and will need to be different per collector name.
`collector_name` is used as part of the path prefix, and needs to be set to the name of the CardinalHQ collector.
`use_path_style` should be `true`.
The other fields are generally obvious.

If you are using a non-AWS S3 provider, there is also an `endpoint` option to list the URL for your S3
endpoint.

## API Keys

API Keys are used to provide access to the data stored in your data lake.  These
are used by the `query-api` and `query-worker` to authenticate and authorize
access to the organiation's data stored in the lake.

These are defined in YAML, via the values file:

```yaml
apiKeys:
  secretName: "apikeys" # will have the format <release-name>-apikeys once deployed
  create: true
  yaml: []
    - organization_id: dddddddd-aaaa-4ff9-ae8f-365873c552f0
      keys:
        - my-api-key-1
        - my-api-key-2
```

The `organization_id` should match ones used in the storage profile.

Multiple keys can be used.  If the Lakerunner query API is not used, these can be left blank.

## Grafana Configuration

LakeRunner includes an integrated Grafana instance for visualization and dashboards. The chart provides simplified configuration for the Cardinal LakeRunner datasource.

### Basic Configuration

The minimal configuration requires only an API key:

```yaml
grafana:
  cardinal:
    apiKey: "your-api-key-here"  # Must match a key from apiKeys configuration
```

This automatically:
- Configures the Cardinal LakeRunner datasource
- Sets the endpoint to the deployed query-api service
- Makes it the default datasource in Grafana

### Advanced Configuration

You can customize the Cardinal datasource:

```yaml
grafana:
  cardinal:
    apiKey: "your-api-key-here"
    endpoint: "http://custom-query-api:8080"  # Optional: custom endpoint
    name: "My Cardinal Instance"             # Optional: custom name (default: "Cardinal")
    isDefault: false                         # Optional: not the default datasource
    editable: false                          # Optional: read-only in Grafana UI
```

### Multiple Replicas and External Database

For high availability with multiple Grafana replicas, you must configure an external database since SQLite cannot be shared:

```yaml
grafana:
  replicas: 3  # Requires external database
  cardinal:
    apiKey: "your-api-key-here"
  env:
    - name: GF_DATABASE_TYPE
      value: "postgres"
    - name: GF_DATABASE_HOST
      valueFrom:
        secretKeyRef:
          name: grafana-db-secret
          key: host
    - name: GF_DATABASE_NAME
      value: "grafana"
    - name: GF_DATABASE_USER
      valueFrom:
        secretKeyRef:
          name: grafana-db-secret
          key: username
    - name: GF_DATABASE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: grafana-db-secret
          key: password
```

### Additional Datasources

You can add additional datasources alongside the Cardinal datasource:

```yaml
grafana:
  cardinal:
    apiKey: "cardinal-key"
  datasources:
    prometheus.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://prometheus:9090
```

### Environment Variables

Grafana supports configuration via environment variables. Common examples:

```yaml
grafana:
  env:
    - name: GF_SECURITY_ADMIN_PASSWORD
      value: "custom-admin-password"
    - name: GF_SMTP_ENABLED
      value: "true"
    - name: GF_SMTP_HOST
      value: "smtp.example.com:587"
```

For the complete list of Grafana configuration options, see the [Grafana documentation](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/).

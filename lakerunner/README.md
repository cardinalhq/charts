# Lakerunner

## Requirements

* A Kubernetes cluster running a modern version of Kubernetes, at least 1.28.
* A PostgreSQL database, at least version 16.
* An S3 (or compatible) object store configured to send object create notifications either via SQS or a web hook.

For AWS S3, SQS queues for bucket notifications should be used.  Other systems may have
other mechanisms, and a webhook-style receiver can be enabled to support them.

## Installation

Create a `values-local.yaml` file (see below) and run:

```sh
helm install lakerunner oci://public.ecr.aws/cardinalhq.io/lakerunner \
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

* Configures the Cardinal LakeRunner datasource
* Sets the endpoint to the deployed query-api service
* Makes it the default datasource in Grafana

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

## Default Resource Requirements

The following table summarizes the default resource requirements for each LakeRunner component as configured in the default `values.yaml`:

| Component | CPU | Memory | Temp Storage |
|-----------|-----|--------|--------------|
| **PubSub Components** ||||
| pubsub.HTTP | 200m | 200Mi | - |
| pubsub.SQS | 200m | 200Mi | - |
| pubsub.GCP | 200m | 200Mi | - |
| pubsub.Azure | 200m | 200Mi | - |
| **Data Ingestion** ||||
| ingestLogs | 1200m | 1Gi | 10Gi |
| ingestMetrics | 1200m | 1Gi | 10Gi |
| ingestTraces | 1200m | 1Gi | 10Gi |
| **Data Processing** ||||
| boxerRollupMetrics | 500m | 128Mi | - |
| boxerCompactMetrics | 500m | 128Mi | - |
| boxerCompactLogs | 500m | 128Mi | - |
| boxerCompactTraces | 500m | 128Mi | - |
| compactLogs | 1200m | 500Mi | 10Gi |
| compactMetrics | 1200m | 500Mi | 10Gi |
| compactTraces | 1200m | 500Mi | 10Gi |
| rollupMetrics | 1200m | 500Mi | 10Gi |
| **Query Layer** ||||
| queryApi | 2000m | 4Gi | 16Gi |
| queryWorker | 4000m | 6Gi | 16Gi |
| sweeper | 250m | 300Mi | - |
| **Infrastructure** ||||
| setup | 1100m | 250Mi | - |
| monitoring | 250m | 100Mi | - |
| **Add-Ons** ||||
| grafana | 200m | 256Mi | - |

**Notes:**

* Resource values are based on the default `values.yaml` configuration
* These settings are suitable for small to medium installations
* Adjust these values based on your specific workload requirements
* Components with autoscaling enabled can scale between configured min/max replicas
* Temporary storage is used for processing intermediate data and caching and will benefit from fast local epheremal storage.
* PubSub components are mutually exclusive - typically only one is enabled based on your cloud provider

## Security context / Pod Security Standards

Every workload runs under a hardened `securityContext` by default:

* `runAsNonRoot: true`, `runAsUser`/`runAsGroup`/`fsGroup: 65532` at the pod level (Grafana overrides these to `472` because its upstream image requires that user)
* `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`, and `readOnlyRootFilesystem: true` at the container level (Grafana sets `readOnlyRootFilesystem: false` because it writes to `/var/lib/grafana`)

The defaults satisfy Kubernetes Pod Security Standards `restricted`. The full map lives in `values.yaml` under `global.podSecurityContext` and `global.containerSecurityContext`; per-component overrides can be added as `<component>.podSecurityContext` / `<component>.containerSecurityContext` and the chart will shallow-merge (component wins over global).

## Deploying on OpenShift

The chart renders cleanly under the `restricted-v2` SCC. One adjustment is
always required; a second is required only when `grafana.enabled: true`.

### 1. Let the SCC assign UIDs (always required)

OpenShift's `restricted-v2` SCC rejects pods whose `runAsUser`/`runAsGroup`/
`fsGroup` fall outside the namespace's assigned UID range — it wants to
inject those values from the range itself. The chart defaults to UID 65532,
which almost never falls inside that range. Null the fields in your
`values-local.yaml`:

```yaml
global:
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: null
    runAsGroup: null
    fsGroup: null
```

With those in place the pod `securityContext` emits only `runAsNonRoot:
true` and the SCC fills in the rest. All other hardening (no-privilege-
escalation, drop ALL, RuntimeDefault seccomp, read-only rootfs) stays in
effect.

### 2. Grafana needs an SCC that permits UID 472 (only if `grafana.enabled: true`)

> Skip this section if `grafana.enabled: false` (the chart default).

The upstream `grafana/grafana` image expects UID 472 to own
`/var/lib/grafana`. That UID almost never falls inside a namespace's
restricted-v2 range, so Grafana needs either a custom SCC or an
OpenShift-compatible image. The simplest path is to bind `nonroot-v2` (which
allows any non-root UID) to the chart's ServiceAccount:

```sh
oc adm policy add-scc-to-user nonroot-v2 \
  -z $(helm get values <release> -n <namespace> -o json | jq -r '.serviceAccount.name // "lakerunner"') \
  -n <namespace>
```

For a stock install (`serviceAccount.name: lakerunner`, release name
`lakerunner`) that's just:

```sh
oc adm policy add-scc-to-user nonroot-v2 -z lakerunner -n <namespace>
```

Grafana's `podSecurityContext` can then stay at its chart default (UID 472).
If you prefer to avoid the SCC grant entirely, swap `grafana.image.repository`
for an OpenShift-compatible image that supports random UIDs and also null
`grafana.podSecurityContext.runAsUser`/`runAsGroup`/`fsGroup` the same way as
section 1.

### 3. Perch needs elevated RBAC

The Perch component already ships with a `ClusterRole` that includes `patch` on `apps/deployments` cluster-wide — this is its legitimate function (cross-namespace deployment management), but it counts as a privileged grant. On clusters with strict RBAC review you may need admin approval or an `oc adm policy add-role-to-user edit` against the chart's ServiceAccount.

### 4. Ingress / Routes

The chart uses standard `networking.k8s.io/v1` `Ingress` resources. They work with the OpenShift HAProxy router out of the box; no nginx-specific annotations are emitted.

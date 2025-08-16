# Lakerunner

## Requirements

* A Kubernetes cluster running a modern version of Kubernetes, at least 1.28.
* A PostgreSQL database, at least version 16.
* An S3 (or compatible) object store configured to send object create notifications.
* (Optional but **highly recommended**) [KEDA](https://keda.sh/) installed in your cluster for intelligent autoscaling.

For AWS S3, SQS queues are used (which the helm chart assumes).  Other systems may have
other mechanisms, and a webhook-style receiver can be enabled to support them.

**Note on Scaling**: CPU-based autoscaling (HPA) is insufficient for micro-batch workloads and may cause poor performance. KEDA provides work queue-based scaling that intelligently responds to actual workload backlog, making it highly recommended for production environments.

## Installation

Create a `values-local.yaml` file (see below) and run:

```sh
helm install lakerunner oci://public.ecr.aws/cardinalhq.io/lakerunner \
   --version 0.2.36 \
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
* Inter-process token
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
    mode: "keda"  # Options: "hpa", "keda", "disabled"
  keda:
    enabled: true
```

### Scaling Modes

LakeRunner supports three scaling modes:

- **`hpa`** (default): CPU-based horizontal pod autoscaling. Suitable for development but insufficient for production micro-batch workloads.
- **`keda`**: Work queue-based scaling using PostgreSQL queries. **Recommended for production** as it scales based on actual workload backlog.
- **`disabled`**: No autoscaling; uses static replica counts.

You can set a global scaling mode and override it per component:

```yaml
global:
  autoscaling:
    mode: "keda"  # Global setting

ingestLogs:
  autoscaling:
    mode: "hpa"  # Override for this component only
```

### How KEDA Scaling Works

KEDA scales components based on actual work queue depth:

- **Ingest components** scale based on unclaimed entries in the `inqueue` table
- **Processing components** scale based on runnable jobs in the `work_queue` table  
- **Intelligent thresholds** prevent over-scaling and ensure responsive performance
- **Cooldown periods** prevent flapping during batch processing

### KEDA Configuration

Each scalable component supports KEDA configuration:

```yaml
ingestLogs:
  autoscaling:
    keda:
      pollingInterval: 30    # How often to check queue (seconds)
      cooldownPeriod: 300    # Wait before scaling down (seconds)
      minReplicaCount: 1     # Minimum replicas (can be 0)
      maxReplicaCount: 10    # Maximum replicas
      postgresql:
        targetQueryValue: 100           # Scale up threshold
        activationTargetQueryValue: 10  # Start scaling threshold
```

**Important**:
- KEDA automatically creates and manages HPA resources. Do not deploy both KEDA ScaledObjects and manual HPA for the same workload as this will cause conflicts.
- KEDA uses the same PostgreSQL database configuration as LakeRunner (`database.lrdb.*` settings). If your database is in a different namespace, ensure the `database.lrdb.host` value uses a full service URL (e.g., `postgresql.database.svc.cluster.local`) as KEDA will need to contact PostgreSQL from the `keda-system` namespace.

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

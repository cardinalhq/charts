# CardinalHQ Collector Base Manifests

Kustomize-based manifests for deploying the CardinalHQ OTel collector stack. Three components:

| Component | Kind | Purpose |
| ----------- | ------ | --------- |
| **agent** | DaemonSet | Runs on every node. Receives OTLP (4317/4318), scrapes kubelet stats, enriches with k8s attributes, forwards to gateway. Uses `hostNetwork`. |
| **poller** | Deployment (1 replica) | Watches cluster-level k8s objects (pods, nodes, deployments, HPAs, etc.) and forwards metrics to gateway. |
| **gateway** | Deployment (2 replicas) | Receives from agent/poller and external OTLP sources, load-balances external metrics across pods, exports everything to S3. Also generates service graph metrics from traces. |

## Prerequisites

### S3-Compatible Object Storage

- **Endpoint URL** — e.g. `https://s3.us-east-2.amazonaws.com` or a MinIO/Ceph endpoint
- **Bucket name** — the bucket for raw OTEL data
- **Region** — the S3 region (or a logical name for non-AWS)
- **Access Key ID** and **Secret Access Key** — credentials with write access to the bucket
- **Role ARN** (optional) — if using IAM role assumption, set this; otherwise leave empty

### Cluster

- A Kubernetes cluster with kustomize available (`kubectl apply -k`)

## Configuration

### 1. Secrets (`gateway/secrets.yaml`)

Edit `gateway/secrets.yaml` and replace the placeholder values:

```yaml
# aws-credentials secret
AWS_ACCESS_KEY_ID: "your-access-key"
AWS_SECRET_ACCESS_KEY: "your-secret-key"
```

### 2. Environment Variables

#### All three components (`agent/daemonset.yaml`, `poller/deployment.yaml`, `gateway/deployment.yaml`)

| Variable | Description | Example |
| ---------- | ------------- | --------- |
| `K8S_CLUSTER_NAME` | Logical name for your cluster | `production-us-east` |

#### Gateway only (`gateway/deployment.yaml`)

| Variable | Description | Example |
| ---------- | ------------- | --------- |
| `AWS_REGION` | S3 region | `us-east-2` |
| `AWS_S3_ENDPOINT` | S3 endpoint URL | `https://s3.us-east-2.amazonaws.com` |
| `AWS_S3_BUCKET` | Bucket name | `datalake-my-org` |
| `AWS_ROLE_ARN` | IAM role ARN (leave `""` if using keys) | `arn:aws:iam::123456:role/s3writer` |
| `LAKERUNNER_ORGANIZATION_ID` | Your org UUID (used in the S3 prefix path) | `b932c6f0-b968-4ff9-ae8f-365873c552f0` |

### 3. Optional Tuning

| What | Where | Default |
| ------ | ------- | --------- |
| Agent memory limit | `agent/daemonset.yaml` resources | 500Mi |
| Poller memory limit | `poller/deployment.yaml` resources | 500Mi |
| Gateway replicas | `gateway/deployment.yaml` `.spec.replicas` | 2 |
| Gateway memory limit | `gateway/deployment.yaml` resources | 2Gi |
| Collector image tag | All three `image:` fields | `v1.5.0` |

### 4. Namespace

The namespace defaults to `collector` (set in `kustomization.yaml`). To change it, update the `namespace:` field in `kustomization.yaml` and `namespace.yaml`. The agent and poller configs hardcode the gateway interproc service as `collector-gateway-interproc:24318` using short DNS — this works as long as all components are in the same namespace.

## Deploy

```bash
# Preview
kubectl kustomize base-collector-manifests/

# Apply
kubectl apply -k base-collector-manifests/
```

## Using Kustomize Overlays

To customize per-environment without editing base files, create an overlay:

```text
overlays/
  production/
    kustomization.yaml
```

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base-collector-manifests

patches:
  - target:
      kind: Deployment
      name: collector-gateway
    patch: |
      - op: replace
        path: /spec/replicas
        value: 4
```

## Architecture

```text
  Workloads (OTLP 4317/4318)
        │
        ▼
  ┌──────────────┐     ┌──────────────┐
  │  agent (DS)  │     │ poller (1x)  │
  │  per-node    │     │ k8s_cluster  │
  └──────┬───────┘     └──────┬───────┘
         │                    │
         │   OTLP/HTTP :24318 │
         └────────┬───────────┘
                  ▼
         ┌────────────────┐     External OTLP
         │  gateway (2x)  │◄─── (4317/4318)
         │  servicegraph  │
         │  S3 export     │──► S3 bucket
         └────────────────┘
```

## Data Flow

**Agent/Poller → Gateway (interproc, port 24318)**:

- Agent and poller pre-convert cumulative metrics to delta before sending.
- Gateway receives pre-delta'd data and writes straight to S3 (no load-balancing needed).

**External OTLP → Gateway (ports 4317/4318)**:

- External sources may send cumulative metrics.
- Gateway load-balances external metrics by stream ID across pods, then applies cumulative-to-delta conversion before writing to S3.
- External logs and traces go straight to S3.

**Servicegraph**: All traces (interproc and external) feed into the `servicegraph` connector, which generates span-derived metrics (call counts, latency) written to S3.

## Troubleshooting

- **health check**: port 13133 `/healthz` on all pods
- Check logs: `kubectl logs -n collector -l app.kubernetes.io/instance=collector-agent`

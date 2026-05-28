# CardinalHQ Collector Base Manifests

Kustomize-based manifests for deploying the CardinalHQ OTel collector stack. Three components:

| Component | Kind | Purpose |
| ----------- | ------ | --------- |
| **agent** | DaemonSet | Runs on every node. Receives OTLP (4317/4318) via the `collector-agent` Service (`internalTrafficPolicy: Local`), scrapes kubelet stats, enriches with k8s attributes, forwards to gateway. |
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
| Collector image tag | All three `image:` fields | `v1.7.0` |

### 4. Namespace

The namespace defaults to `collector` (set in `kustomization.yaml`). To change it, update the `namespace:` field in `kustomization.yaml` and `namespace.yaml`. The agent and poller configs hardcode the gateway interproc service as `collector-gateway-interproc:24318` using short DNS — this works as long as all components are in the same namespace.

### 4a. Self-telemetry

Each component is configured to ship its own internal logs and metrics over
OTLP/HTTP to the agent running on the same node (`http://${HOST_IP}:4318`).
The agent enriches and forwards them upstream like any other workload's
telemetry; stderr output is preserved so `kubectl logs` keeps working. Each
component sets a distinct `service.name` (`collector-agent`,
`collector-poller`, `collector-gateway`) so emitters can be told apart
downstream.

To opt out, delete the `processors:` and `readers:` blocks under
`service.telemetry` in the relevant configmap.

### 4b. S3 upload notifications (optional)

The gateway's `awss3` exporter can POST an AWS-S3-event-shaped JSON
envelope to an HTTP receiver after each successful upload. This is the
intended hook for lakerunner's `pubsub-http` ingester and is disabled by
default. To enable, uncomment the `notifications` block in
`gateway/configmap.yaml` and set `endpoint` to your receiver, e.g.
`http://lakerunner-pubsub-http.<ns>.svc.cluster.local:8080/`.

Operator-facing metrics emitted by the notifier (under scope
`github.com/open-telemetry/opentelemetry-collector-contrib/exporter/awss3exporter`):

| Metric | Type | Attributes |
| --- | --- | --- |
| `notifications.sent` | counter, per record | `outcome=success` |
| `notifications.dropped` | counter, per record | `reason={queue_full, permanent_4xx, retries_exhausted, shutdown}` |
| `notifications.send.duration` | histogram, per HTTP attempt (seconds) | `status_class={2xx, 4xx, 5xx, network_error}` |

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
  └──┬────────┬──┘     └───────┬──────┘
     │ logs   │ metrics+traces │ metrics
     │        │ (LB by stream/ │ (LB by streamID)
     │        │  traceID)      │
     │  :24318│      :14317    │ :14317
     ▼        ▼                ▼
  ┌──────────────────────────────────┐    External OTLP
  │           gateway (2x)           │◄── (4317/4318)
  │   L1 (external) → L2 (balanced)  │
  │   servicegraph + S3 export       │──► S3 bucket
  └──────────────────────────────────┘
```

## Data Flow

The gateway runs a two-stage (L1/L2) pipeline for metrics and traces. L1 is
stateless and load-balances by stream/trace ID across gateway pods over the
`collector-gateway-headless` Service on port 14317; L2 receives the balanced
data and runs stateful processors (`cumulativetodelta`, `aggregation/s3`,
`servicegraph`).

**Agent/Poller → Gateway**:

- Logs: agent → gateway interproc HTTP (`collector-gateway-interproc:24318`).
- Metrics: agent and poller pre-convert cumulative to delta locally, then
  use a `loadbalancing` exporter (`routing_key: streamID`) to send straight
  into gateway L2 on port 14317, skipping the gateway's L1 hop.
- Traces: agent uses a `loadbalancing` exporter (`routing_key: traceID`)
  to send straight into gateway L2 on port 14317, so `servicegraph` sees
  complete traces.
- The agent/poller need a namespace `Role` granting `endpoints` watch (the
  `loadbalancing` exporter's k8s resolver discovers gateway pods via the
  headless Service's endpoints). The default `agent/role.yaml` and
  `poller/role.yaml` provide this.

**External OTLP → Gateway (ports 4317/4318)**:

- External sources may send cumulative metrics.
- Gateway load-balances external metrics by stream ID across pods (L1 →
  L2), then applies cumulative-to-delta conversion before writing to S3.
- External traces fan out to both the load balancer (for `servicegraph`)
  and directly to S3 from L1, so raw spans land in S3 without an extra
  hop.
- External logs go straight to S3.

**Servicegraph**: runs in the L2 traces pipeline only, so a given trace's
spans always land on a single pod regardless of source.

## Troubleshooting

- **health check**: port 13133 `/healthz` on all pods
- Check logs: `kubectl logs -n collector -l app.kubernetes.io/instance=collector-agent`

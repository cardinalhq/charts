# Design: Colocate control-plane singletons into one pod

**Date:** 2026-06-01
**Chart:** lakerunner
**Status:** Implemented (chart 3.13.0)

## Problem

Four lakerunner components run as separate single-replica Deployments, each its
own pod: `admin-api`, `alert-evaluator`, `monitoring`, and `sweeper`. All four
run the same `lakerunner` image with different subcommands, are natural
singletons (`replicas: 1`), and use trivial resources in practice (~7m CPU /
~87Mi memory combined, observed live). Yet they reserve **2.75 cores / 1.7Gi**
of scheduler capacity across four pods.

Running four pods for four tiny always-on singletons is wasteful overhead. We
want to colocate them into a single pod and right-size it.

## Goal

Replace the four Deployments with one Deployment, `lakerunner-control-plane`,
that runs all four as containers in a single pod, and reduce reserved capacity.

Non-goals: changing what the binaries do; merging them into one process (that is
a future lakerunner-binary feature, out of scope for the chart); making
colocation optional.

## Decisions (locked with stakeholder)

1. **Always colocate.** No feature flag, no per-component `enabled` flags. All
   four containers are always present in the pod.
2. **Right-size down, burst-friendly.** Per-container resources sized to
   measured prod usage. **CPU: requests only, no limits** (compressible — lets
   any container burst into idle node/sibling capacity instead of being
   throttled). **Memory: request + a per-container limit** (non-compressible —
   the limit confines an OOM/leak to the offending container instead of taking
   down its podmates). Per-container blocks, not a single shared envelope, so
   each can be tuned independently.
3. **Name:** `control-plane` → Deployment/pod `lakerunner-control-plane`,
   component label `app.kubernetes.io/component: control-plane`.
4. **Deprecated keys hard-fail.** Removed values keys trigger `{{ fail }}` with
   migration guidance (consistent with the existing `deprecation-warnings.yaml`
   pattern), so stale configs cannot rot silently.

## Why this is feasible (binary check)

The shared health-check port (8090) is the only blocker to colocation: pod
containers share one network namespace, so four processes binding `:8090` would
collide. Confirmed in the lakerunner repo that
`internal/healthcheck/server.go:GetConfigFromEnv()` reads `HEALTH_CHECK_PORT`
(default 8090), and all four target subcommands call it
(`cmd/admin_api.go`, `cmd/monitoring.go`, `cmd/sweeper.go`,
`cmd/alert_evaluator.go`). So distinct ports can be assigned per container via
env, **no binary change required**. Port audit confirmed only admin-api binds a
second port (HTTP `:9091`); the others bind only their health port.

## Design

### New template: `templates/control-plane-deployment.yaml`

One `Deployment` named `lakerunner-control-plane`, `replicas: 1`, four
containers from the shared `lakerunner` image. Always rendered (no `enabled`
guard).

Pod-level (shared):
- `serviceAccountName`: existing shared SA.
- `podSecurityContext`: `controlPlane.podSecurityContext`.
- Scheduling: single `controlPlane.nodeSelector` / `.tolerations` / `.affinity`
  (merged with `global.*` via the existing `lakerunner.sched.*` helpers).
- Pod label `azure.workload.identity/use: "true"` when
  `cloudProvider.azure.authType == "workload_identity"` (sweeper +
  alert-evaluator require it).
- `imagePullSecrets`, license volume, standard labels/annotations.

Per container — health ports assigned distinctly:

| Container        | args                            | `HEALTH_CHECK_PORT` | port name | other ports |
|------------------|---------------------------------|---------------------|-----------|-------------|
| admin-api        | `admin-api serve --port=9091`   | 8090                | hc-admin  | http 9091   |
| alert-evaluator  | `alert-evaluator`               | 8091                | hc-alert  | —           |
| monitoring       | `monitoring serve`              | 8092                | hc-mon    | —           |
| sweeper          | `sweeper`                       | 8093                | hc-sweep  | —           |

Per-container env/config preserved from today:
- **admin-api:** `--port` HTTP listener + http container port.
- **alert-evaluator:** `ALERT_EVALUATOR_QUERY_API_URL` (default to internal
  query-api), azure auth env, cloud-cred `envFrom`.
- **monitoring:** `autoscalerEnv`.
- **sweeper:** azure auth env, cloud-cred `envFrom`, `storage-profiles`
  configMap volume mount (when `storageProfiles.source == "config"`).
- All four: `POD_NAMESPACE/NAME/IP`, `OTEL_SERVICE_NAME` (per-container, keeps
  distinct telemetry identity), `TMPDIR=/scratch`, `injectEnv`,
  `cardinalTelemetryEnv`.

Each container gets its own `resources` block (see values below): CPU requests
only (no CPU limit), memory request + memory limit.

### Health-probe helper change

`lakerunner.healthProbes` currently hardcodes the probe target port name
`healthcheck`. Generalize it to accept a port-name argument so each container's
probes can target its own named port (`hc-admin`, etc.). Default the argument to
`healthcheck` so the other (unchanged) deployments keep working.

### Volumes

- Four separate `scratch` emptyDirs (one per container, each mounted at
  `/scratch`), because every container sets `TMPDIR=/scratch` and a shared dir
  would collide.
- `storage-profiles` configMap volume (sweeper), gated on
  `storageProfiles.source == "config"`.
- Shared read-only license volume.

### Service

Keep `admin-api-service.yaml` and the service name `lakerunner-admin-api`
(stable for any external references). Change its selector from
`component: admin-api` to `component: control-plane` so it targets the merged
pod. admin-api is the only container binding HTTP `:9091`, so the service still
resolves to exactly one listener.

### Deleted templates

- `templates/admin-api-deployment.yaml`
- `templates/alert-evaluator-deployment.yaml`
- `templates/monitoring-deployment.yaml`
- `templates/sweeper-deployment.yaml`

## values.yaml changes

New block:

```yaml
controlPlane:
  replicas: 1            # singleton; not intended to scale
  image:
    repository: ghcr.io/cardinalhq/lakerunner
    tag: ""
    pullPolicy: ""
  podSecurityContext: {}
  containerSecurityContext: {}
  labels: {}
  annotations: {}
  nodeSelector: {}
  tolerations: []
  affinity: {}
  # Per-container resources. CPU: requests only (no limit) so any container can
  # burst into idle node/sibling capacity. Memory: request + limit so a leak is
  # confined to one container, not the whole pod. Sized to measured prod usage.
  resources:
    adminApi:
      requests: { cpu: "25m", memory: 64Mi }
      limits:   { memory: 256Mi }
    alertEvaluator:
      requests: { cpu: "25m", memory: 64Mi }
      limits:   { memory: 256Mi }
    monitoring:
      requests: { cpu: "25m", memory: 64Mi }
      limits:   { memory: 256Mi }
    sweeper:
      requests: { cpu: "50m", memory: 64Mi }
      limits:   { memory: 256Mi }
```

Pod reserves **125m CPU / 256Mi memory** (sum of requests); no CPU limit on any
container; each container capped at 256Mi memory.

The four existing blocks shrink to only their container-specific keys:
- `adminApi`: `port`, `service`
- `alertEvaluator`: `queryApiUrl`, `env`
- `monitoring`: `autoscaler`
- `sweeper`: (none beyond global storage-profiles)

Removed from each: `enabled`, `replicas`, `resources`, `image`, `nodeSelector`,
`tolerations`, `affinity`, security contexts, `labels`, `annotations` (now
pod-level under `controlPlane`).

## Deprecation handling

Add hard-fail guards to `templates/deprecation-warnings.yaml` for the removed
keys, matching the existing `{{ fail }}` style. Triggers (each with a migration
message pointing at `controlPlane.*`):
- `adminApi.enabled`, `alertEvaluator.enabled`, `monitoring.enabled`,
  `sweeper.enabled` set.
- Per-component `replicas` / `resources` / `image` / scheduling keys set.

Because the shipped `values.yaml` no longer defines these keys, a default render
does not fail; only users carrying stale overrides hit the guard, with a clear
message telling them to move settings to `controlPlane.*`.

## Versioning

Breaking values change → bump `Chart.yaml` `version` (currently `3.12.24`).
`appVersion` unchanged (no binary change). Document the migration in the chart
changelog / PR description.

## Testing / verification

- `helm lint lakerunner`.
- `helm template` with default values: renders one `lakerunner-control-plane`
  Deployment with four containers, four distinct `HEALTH_CHECK_PORT` values and
  unique port names, admin-api http 9091, service selector
  `component: control-plane`; no `admin-api`/`alert-evaluator`/`monitoring`/
  `sweeper` standalone Deployments remain.
- `helm template` with each azure / storage-profiles=config / cloud-cred path
  enabled: verify pod label, `storage-profiles` mount, `envFrom`.
- `helm template` with a deprecated key set (e.g. `sweeper.enabled=true`): render
  fails with the migration message.
- Confirm summed container requests = 125m / 256Mi; no `limits.cpu` on any
  container; each container has `limits.memory: 256Mi`.

## Impact

Reserved capacity drops from **2.75 cores / 1.7Gi** (four pods) to **125m CPU /
256Mi memory** (one pod) — reclaiming **~2.6 cores and ~1.5Gi**. CPU has no
ceiling, so any container bursts into idle node/sibling capacity under load;
memory is capped per-container at 256Mi (~10× observed) to confine leaks. Pod
count for these services: 4 → 1.

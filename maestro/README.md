# Maestro

Maestro is CardinalHQ's AI agent server with an MCP gateway companion. This chart deploys both components plus an optional `Ingress` for the UI.

## Requirements

* A Kubernetes cluster running a modern version of Kubernetes, at least 1.28.
* A PostgreSQL database, at least version 13.

## Installation

```sh
helm install maestro oci://public.ecr.aws/cardinalhq.io/maestro \
   --values values-local.yaml \
   --namespace maestro --create-namespace
```

## `values-local.yaml`

See [`values.yaml`](https://github.com/cardinalhq/charts/blob/main/maestro/values.yaml) for the full set of defaults. The minimum you need to supply:

* `database.host` — PostgreSQL hostname
* `database.password` (if `database.create: true`) or an existing secret name via `database.secretName` (with `database.create: false`)
* `mcpGateway.apiKey` if the gateway is enabled

## Security context / Pod Security Standards

Both workloads (`maestro`, `mcp-gateway`) and the `wait-for-mcp-gateway` init container run under a hardened `securityContext` by default:

* `runAsNonRoot: true`, `runAsUser`/`runAsGroup`/`fsGroup: 65532` at the pod level
* `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`, `readOnlyRootFilesystem: true` at the container level

The defaults satisfy Kubernetes Pod Security Standards `restricted`. The map lives in `values.yaml` under `global.podSecurityContext` and `global.containerSecurityContext`; per-component overrides can be added as `maestro.podSecurityContext` / `mcpGateway.podSecurityContext` (and the `.containerSecurityContext` siblings) — the chart shallow-merges with component fields winning over global.

The `wait-for-mcp-gateway` init container pulls `busybox:1.36` pinned to its multi-arch manifest list digest (`waitContainer.image.digest` in `values.yaml`), so pulls are reproducible but still resolve to the correct per-architecture variant at runtime. Clear the digest or point the repository at an internal mirror if needed.

## Deploying on OpenShift

The chart renders cleanly under the `restricted-v2` SCC once the UID fields are nulled out so the SCC can inject values from the namespace's assigned UID range:

```yaml
global:
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: null
    runAsGroup: null
    fsGroup: null
```

With that in place, the rendered pod `securityContext` emits only `runAsNonRoot: true`; the SCC fills in `runAsUser`, `runAsGroup`, and `fsGroup`. All other hardening (no-privilege-escalation, drop ALL, RuntimeDefault seccomp, read-only rootfs) stays in effect.

### Ingress / Routes

The chart uses a standard `networking.k8s.io/v1` `Ingress` resource with a configurable `ingressClassName`. The OpenShift HAProxy router handles it out of the box; no nginx-specific annotations are emitted.

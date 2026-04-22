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

## Bundled Dex (POC only)

For demos and proof-of-concept installs, the chart can spin up a [Dex](https://dexidp.io) OIDC provider alongside Maestro. **This is not for production** — Dex is configured with in-memory storage, so signing keys rotate and all sessions drop on every Dex pod restart, and only a single replica is supported. Use a real IdP (Keycloak, Okta, Auth0, etc.) for anything beyond a POC.

When enabled, the chart renders a Dex `Deployment` + `Service` + `ConfigMap`, routes the path under `dex.pathPrefix` (default `/dex`) on the maestro `Ingress` to Dex, and auto-injects the OIDC env vars on the maestro container so OIDC works end-to-end without a separate IdP. Static users live in `dex.staticUsers` with bcrypt-hashed passwords; users in the group named by `dex.superadminGroup` (default `maestro-superadmin`) become Maestro superadmins.

Minimal overlay:

```yaml
maestro:
  baseUrl: https://maestro.example.com   # or set ingress.host and the chart derives this
ingress:
  enabled: true
  host: maestro.example.com
  tls:
    - hosts: [maestro.example.com]
      secretName: maestro-tls
dex:
  enabled: true
  staticUsers:
    - email: admin@example.com
      username: admin
      userID: "08a8684b-db88-4b73-90a9-3cd1661f5466"
      hash: "$2a$10$..."   # htpasswd -bnBC 10 "" yourpass | tr -d ':\n'
      groups:
        - maestro-superadmin
```

Install will fail loudly if you set `dex.enabled: true` without a usable base URL, without any static users, or with `dex.replicas > 1`.

Note: `dex.superadminGroup` only takes effect once the SPA requests the OIDC `groups` scope (tracked in [conductor#370](https://github.com/cardinalhq/conductor/issues/370)). Until that ships in a Maestro release, grant superadmin via `OIDC_SUPERADMIN_EMAILS` in `maestro.env` instead.

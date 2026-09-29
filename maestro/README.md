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

## Installation system key (`MAESTRO_MCP_API_KEY`)

Maestro admits `MAESTRO_MCP_API_KEY` as the system principal, and the mcp-gateway sidecar needs the same value to call maestro back (storyboard and outcomes tools) and, on the default keyless sidecar, to raise dataset-materialization limits for Investigation Storyboards. The chart puts it into both containers from a single source, first match wins:

1. A `MAESTRO_MCP_API_KEY` entry you already set in `global.env`, `maestro.env` or `mcpGateway.env`. The container that lacks it gets a copy of that entry (same Secret reference).
2. `maestro.systemKeySecret.name` / `.key`: an existing Secret. Use this with GitOps or sealed-secrets.
3. Otherwise a generated Secret `<fullname>-system-key`, kept stable across `helm upgrade` via `lookup`. Plain `helm template` (e.g. ArgoCD) cannot look it up and regenerates it on every render, so GitOps installs should use option 1 or 2.

## Security context / Pod Security Standards

Both workloads (`maestro`, `mcp-gateway`) and the `wait-for-mcp-gateway` init container run under a hardened `securityContext` by default:

* `runAsNonRoot: true`, `runAsUser`/`runAsGroup`/`fsGroup: 65532` at the pod level
* `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`, `readOnlyRootFilesystem: true` at the container level

The defaults satisfy Kubernetes Pod Security Standards `restricted`. The map lives in `values.yaml` under `global.podSecurityContext` and `global.containerSecurityContext`; per-component overrides can be added as `maestro.podSecurityContext` / `mcpGateway.podSecurityContext` (and the `.containerSecurityContext` siblings) — the chart shallow-merges with component fields winning over global.

The `wait-for-mcp-gateway` init container reuses the unified maestro image and runs its built-in `wait-for-tcp` entrypoint subcommand, so the chart does not depend on a second image (no `busybox`/`netcat` pull) for readiness gating.

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

### Single-endpoint deployments (POC bastion port-forwards)

When `dex.enabled: true` (chart 0.5.24+ with maestro v1.7.16+), the chart wires the maestro pod to also serve the Dex `/<dex.pathPrefix>/*` paths by reverse-proxying to the in-cluster Dex Service. This makes the install reachable through any path that reaches the maestro Service alone — for example a single `kubectl port-forward --address 0.0.0.0 svc/<release>-maestro 8080:4200` on a bastion host. Set `maestro.baseUrl` to the URL the browser will use (e.g. `http://1-2-3-4.nip.io:8080` or `http://<bastion-ip>:8080`) and the OIDC issuer composes correctly without an Ingress.

Ingress-based installs are unaffected: the Ingress's `/dex` path rule path-matches first and routes directly to the Dex Service, so the in-pod proxy is never exercised in that flow.

Set `dex.proxyEnabled: false` to opt out (env vars are not emitted; the maestro pod returns 404 for `/<pathPrefix>/*` and an Ingress is required for the OIDC flow to work).

#### HTTPS at the maestro Service (chart 0.5.25+)

When the consumer requires HTTPS but no Ingress controller is doing TLS termination — for example a POC bastion port-forward that the customer's policy mandates be served over TLS — set `maestro.tls.enabled: true`. The chart adds an nginx-unprivileged sidecar in the maestro pod that listens on `maestro.tls.port` (default `4443`) and proxies to the maestro container on localhost. The maestro Service exposes the new HTTPS port alongside the existing HTTP one.

Pick exactly one of three certificate sources:

```yaml
maestro:
  baseUrl: https://1-2-3-4.nip.io:8443
  tls:
    enabled: true
    cert:
      # 1. autoGenerate (default) — self-signed cert generated at pod start
      # with SAN = host of maestro.baseUrl + cert.sans extras. Cert
      # regenerates on every pod restart, so browsers re-prompt for trust.
      autoGenerate: true
      sans: []

      # 2. Inline PEM cert + key. The chart creates a kubernetes.io/tls
      # Secret named "<release>-maestro-tls-cert" and the sidecar mounts
      # it. Set `autoGenerate: false` when using this path.
      # crt: |
      #   -----BEGIN CERTIFICATE-----
      #   ...
      # key: |
      #   -----BEGIN PRIVATE KEY-----
      #   ...

    # 3. Reference an existing kubernetes.io/tls Secret (cert-manager,
    # manual creation, etc.). Set cert.autoGenerate: false when using it.
    # secretName: my-tls
ingress:
  enabled: false
dex:
  enabled: true
  staticUsers: [...]
```

```sh
kubectl port-forward --address 0.0.0.0 svc/<release>-maestro 8443:4443
```

For an IP-only POC bastion (no DNS), generate a matching self-signed cert
with the bundled helper and feed the files in via `helm --set-file`:

```sh
maestro/scripts/gen-tls-cert.sh 1.2.3.4 --out-dir /tmp/maestro-tls
helm upgrade --install <release> oci://public.ecr.aws/cardinalhq.io/maestro \
  --values values-local.yaml \
  --set maestro.tls.enabled=true \
  --set maestro.tls.cert.autoGenerate=false \
  --set-file maestro.tls.cert.crt=/tmp/maestro-tls/tls.crt \
  --set-file maestro.tls.cert.key=/tmp/maestro-tls/tls.key
```

The script validates the dotted-quad format, emits `tls.crt`/`tls.key`
with `IP:1.2.3.4` as the SAN, and prints the matching helm command on
stdout. Use `--extra-san DNS:bastion.local` (repeatable) to add more
SANs when the same install is reachable through multiple hostnames.

The chart fails template rendering when `tls.enabled: true` and the
resolved base URL isn't `https://`, so OIDC URLs always match the served
scheme. It also fails when more than one cert source is configured, or
when only one of `cert.crt`/`cert.key` is set.

All sidecar/init images are overridable: `maestro.tls.image.{repository,tag,pullPolicy}` for the nginx sidecar, `maestro.tls.cert.image.{repository,tag,pullPolicy}` for the openssl cert-init. `dex.image.{repository,tag,pullPolicy}` overrides the bundled Dex image (defaults in `templates/_helpers.tpl`).

## Proxy hops, public storyboard links and MCP OAuth

All three are off by default; an install that sets none of them renders exactly as before.

### `maestro.trustedProxyHops` → `MAESTRO_TRUSTED_PROXY_HOPS`

The number of reverse proxies in front of maestro that append to `X-Forwarded-For` (an Ingress controller is one; a cloud L7 load balancer in front of it is another; an L4 load balancer is not). Maestro sets Express `trust proxy` to it, so IP-keyed rate limits bucket on the real client instead of the ingress pod. Too low is safe (every client shares one bucket, which is what happens today); too high lets a client choose its own IP. Rendering fails on anything but a non-negative integer. `true` (trust every hop) is refused for that reason.

### `share.host` → `SHARE_HOST`

This is the dedicated, cookie-less host that public storyboard links are served from (`https://<share.host>/s/<token>`). On it maestro serves only `/s/*`, `/api/public/*` and static assets. Rendering fails when the value is not a bare `host[:port]`, or when it equals the app's own host (maestro would 404 the app there). Set `share.ingress.enabled: true` to add a rule for it to the chart's `Ingress`. That needs `ingress.enabled: true`, and if `ingress.tls` is set, one of its entries must list the share host or a matching `*.parent` wildcard. If you route the host some other way (an IngressRoute, the Gateway API or a load balancer), leave it off.

```yaml
maestro:
  trustedProxyHops: 1
ingress:
  enabled: true
  host: maestro.example.com
  tls:
    - hosts: [maestro.example.com, share.example.com]
      secretName: maestro-tls
share:
  host: share.example.com
  ingress:
    enabled: true
```

### `mcpOAuth` → `MCP_OAUTH_*`

This lets MCP clients (claude.ai and Claude Desktop connectors, Claude Code) sign in with OAuth against your IdP and use the org-less `/mcp` endpoint. API-key auth keeps working either way.

| value | env | notes |
| --- | --- | --- |
| `mcpOAuth.enabled` | `MCP_OAUTH_ENABLED` | Needs a base URL (`maestro.baseUrl`, `ingress.host` or `MAESTRO_BASE_URL`), `OIDC_ISSUER_URL` in `maestro.env` or `global.env`, and `dex.enabled: false`. |
| `mcpOAuth.issuer` | `MCP_OAUTH_ISSUER` | Defaults to `OIDC_ISSUER_URL`. Only changes the authorization server advertised to MCP clients; it must issue tokens whose `iss` is `OIDC_ISSUER_URL`. |
| `mcpOAuth.audience` | `MCP_OAUTH_AUDIENCE` | Token `aud` accepted on `/mcp` only. Defaults to `<origin>/mcp`. |
| `mcpOAuth.asMetadataProxy` | `MCP_OAUTH_AS_METADATA_PROXY` | For issuers that publish only OIDC discovery (e.g. Keycloak). |
| `mcpOAuth.selfSignup` | `MCP_OAUTH_SELF_SIGNUP` | For SaaS only. A new connector user with a verified email gets a personal workspace, with daily quotas tunable through `PERSONAL_WORKSPACE_MAX_*`. |

**Self-hosted installs should normally leave this off.** MCP connectors register themselves through OAuth dynamic client registration (DCR). The bundled Dex has no DCR, and the chart registers no connector client in it, so rendering fails if you enable `mcpOAuth` with `dex.enabled`, whether or not `mcpOAuth.issuer` is set. Connect MCP clients with an API key instead.

Maestro checks `/mcp` bearer tokens with the same OIDC verifier as the web app: issuer `OIDC_ISSUER_URL` and its JWKS, plus the MCP audience. `mcpOAuth.issuer` does not add a second verifier, so a connector sent to an IdP that is not `OIDC_ISSUER_URL` gets tokens maestro rejects. To use an IdP that supports DCR or has a pre-registered connector client, make it the web app's OIDC IdP: set `dex.enabled: false` and put `OIDC_ISSUER_URL` (and the other `OIDC_*` vars) in `maestro.env`. Rendering fails when `OIDC_ISSUER_URL` is missing.

When `MAESTRO_BASE_URL` is not set by hand, enabling `mcpOAuth` derives it from `maestro.baseUrl` or `ingress.host`. Maestro also uses that origin for storyboard share URLs when `share.host` is unset.

## Deployment modes: POC vs HA

The chart ships two deployment shapes, gated by a single flag.

### POC mode (default, `ha.enabled: false`)

One `maestro` pod + one `mcp-gateway` pod. Artifact bytes stay in memory. No object store required. This is the minimum-friction install for evaluations.

### HA mode (`ha.enabled: true`)

Two `maestro` pods. **`mcp-gateway` runs as a native sidecar inside every maestro pod** — there is no standalone `mcp-gateway` Deployment or Service. Artifact bytes are required to land in an S3-compatible object store. Maestro `temporaryStorage.enabled` is forbidden under HA (the RWO PVC + `Recreate` strategy combination deadlocks rolling updates at `replicas > 1`).

**Why mcp-gateway is a sidecar, not a Deployment**: most MCP drivers in the gateway (kube, lakerunner, jira, github, built-in tool servers) use stateful Streamable HTTP — a session opened on one pod can't be served by another. A standalone gateway Deployment with `replicas > 1` would round-robin and produce "session not found" errors. Co-locating one gateway per consumer pod and talking to it over loopback eliminates the cross-pod routing entirely. Sessions stay pod-local, no Service in the path. See `cardinalhq/conductor#838` for the upstream tracking issue.

The chart fails template rendering — at install time, not silently at runtime — when any HA invariant is violated:

* `ha.enabled=true` and `objectStore.bucket` is empty
* `ha.enabled=true` and `maestro.temporaryStorage.enabled: true`
* `ha.enabled=true` and explicit `maestro.replicas` or `mcpGateway.replicas` `< 2`
* `objectStore.auth.existingSecret` set but a key-name field is blank

`maestro.replicas` and `mcpGateway.replicas` auto-derive from `ha.enabled` when left unset (null). Explicit operator values always win — they just have to be self-consistent.

### Object store: S3 and S3-compatible

The artifact backend uses the AWS SDK v3 with its **default credential chain**. Either let the chain pick up ambient credentials (IRSA via service-account annotations, EC2 instance profile, EKS Pod Identity, workload-identity webhook) or hand the chart an existing Kubernetes Secret containing `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

AWS S3 via IRSA:

```yaml
ha:
  enabled: true
objectStore:
  bucket: maestro-artifacts
  region: us-east-2
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/maestro-s3
```

Rook-Ceph ObjectBucketClaim (Ceph RGW): the OBC controller creates a Secret with `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` and a ConfigMap with `BUCKET_NAME`/`BUCKET_HOST`/`BUCKET_PORT`. Wire them in:

```yaml
ha:
  enabled: true
objectStore:
  bucket: maestro-artifacts-abc1234       # BUCKET_NAME from the OBC ConfigMap
  endpoint: http://rook-ceph-rgw-store.rook-ceph.svc:80
  forcePathStyle: true                    # required for Ceph/MinIO
  auth:
    existingSecret: maestro-artifacts-obc # the OBC-generated secret
```

For MinIO or another S3-compatible store with non-standard secret keys, override `auth.accessKeyIdKey` / `auth.secretAccessKeyKey` (and `sessionTokenKey` for STS-issued credentials). The chart never creates the secret — it must already exist.

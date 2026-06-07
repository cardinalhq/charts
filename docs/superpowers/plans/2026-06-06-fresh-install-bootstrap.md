# Fresh-Install Bootstrap (Sub-project B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a fresh `conductor` install stand up a working LakeRunner+Maestro from empty DBs — phased migrations, a self-seeded shared admin key, and Maestro auto-provisioning the shared LakeRunner — and prove it end-to-end with a scripted test.

**Architecture:** Two pre-install/pre-upgrade hook Jobs run migrations (lakerunner; maestro-via-mcp-gateway). A persistent, lookup-stable Secret anchors the admin key (or an operator `existingSecret`). A post-install/post-upgrade hook Job seeds that key's SHA-256 hash directly into LakeRunner's `configdb.admin_api_keys` (idempotent). The Maestro deployment gets `MAESTRO_BOOTSTRAP_*` env (admin key from the anchor Secret) and provisions the shared org at boot using its own resilient async-retry worker. A scripted test deploys Postgres 18 + rustfs + a cardinalhq-otel-collector fixture, sends telemetry, and validates it via `query-api` directly and via the Maestro proxy.

**Tech Stack:** Helm 3/4, Go-templated Kubernetes manifests, `psql` (postgres:18-alpine), bash, curl, the `cardinalhq-otel-collector` image.

**Scope boundary:** B implements the **fresh** path with idempotent guards (`ON CONFLICT DO NOTHING`, "skip if admin key exists"). The full **fresh/adopt/error detection state machine** and the adopt-time gating of `MAESTRO_BOOTSTRAP_*` are **sub-project C** — do NOT build them here. B's bootstrap must be structured so C can layer detection on top (see Task 5 note).

**Key verified facts (cite when implementing):**
- Admin-key table (current name, post-rename migration `1755713265`): `admin_api_keys (id UUID default gen_random_uuid() PK, key_hash TEXT NOT NULL UNIQUE, name TEXT NOT NULL, description TEXT, created_at timestamptz default now())`. Hash = lowercase hex `sha256(plaintext)`; `admin-api` `ValidateAPIKey` hashes any presented key the same way and looks it up — **no key-format requirement**.
- Migrations: `lakerunner migrate --databases lrdb,configdb` (golang-migrate self-locks). Maestro migrations: the mcp-gateway binary with `MCP_MIGRATE_ONLY=true` runs them and exits 0 (table `gomigrate_maestro`).
- Ports: query-api `8080`, admin-api `9091`, pubsub-http `8080`.
- Ingest path: object lands in bucket → S3-event JSON POSTed to `pubsub-http:8080` (`{"Records":[{"s3":{"bucket":{"name":...},"object":{"key":...,"size":...}}}]}`) → worklane → process-*. The `cardinalhq-otel-collector` `awss3` exporter can POST these via `s3uploader.notifications.endpoint`.
- `MAESTRO_BOOTSTRAP_*` contract: CORE (required, all 3) `ORG_ID,ORG_NAME,OWNER_EMAIL`; LAKERUNNER (required, all 3) `LAKERUNNER_QUERY_API_URL,LAKERUNNER_ADMIN_API_URL,LAKERUNNER_ADMIN_API_KEY`; BUCKET (optional, all 4 together) `BUCKET_NAME,BUCKET_REGION,BUCKET_CLOUD_PROVIDER,BUCKET_COLLECTOR_NAME`; refinements (optional) `BUCKET_ENDPOINT,BUCKET_ROLE,BUCKET_USE_PATH_STYLE,BUCKET_INSECURE_TLS`. Maestro bootstrap is resilient: it writes a DB row and an async worker retries admin-api with backoff — so admin-api/seed ordering races are tolerated.
- Maestro proxy: `POST /api/lakerunner/{instanceId}/{query|alert}/{subpath}` (mounted at `/api/lakerunner`), needs `X-Org-Id` + user auth (`X-CardinalHQ-API-Key` per-user key or OIDC session); maestro stamps the integration's `x-cardinalhq-api-key` upstream.
- Reference rig to adapt: `../conductor/dev/trial-testenv/` (rustfs + bundled pg + intake collector + scripts) and `base-collector-manifests/gateway/configmap.yaml` (awss3 exporter + notifications).

---

## File Structure

```
conductor/
  values.yaml                                   # + bootstrap: block; lakerunner image → ecr-public
  templates/bootstrap/
    admin-key-secret.yaml                        # persistent lookup-stable anchor Secret (or existingSecret)
    migrate-lakerunner-job.yaml                  # pre-install/upgrade hook: lakerunner migrate
    migrate-maestro-job.yaml                     # pre-install/upgrade hook: mcp-gateway MCP_MIGRATE_ONLY
    key-seed-job.yaml                            # post-install/upgrade hook: psql upsert into admin_api_keys
  templates/maestro/maestro-deployment.yaml      # + MAESTRO_BOOTSTRAP_* env block
  templates/_helpers-lakerunner.tpl              # + conductor.adminKeySecretName, conductor.bootstrapEnabled helpers
test/fresh-install/                              # scripted test rig (NOT part of the chart)
  00-run.sh            # orchestrator
  10-postgres.yaml     # Postgres 18
  20-rustfs.yaml       # rustfs S3 store + bucket create
  30-values.yaml       # conductor fresh-install values
  40-collector.yaml    # cardinalhq-otel-collector fixture (awss3 → rustfs + notify pubsub-http)
  50-send-telemetry.sh # emit logs/metrics/traces
  60-validate.sh       # curl query-api direct + via maestro proxy
  99-teardown.sh
```

Legacy `lakerunner/templates/setup-job.yaml` was copied into `conductor/templates/lakerunner/` by sub-project A; Task 4 repurposes/replaces it (migrations move to the dedicated hook).

---

## Part 1 — Chart bootstrap

### Task 1: Default the lakerunner image to ecr-public

**Files:** Modify `conductor/values.yaml`

- [ ] **Step 1: Find the lakerunner image repository default**

Run: `grep -n 'ghcr.io/cardinalhq/lakerunner' conductor/values.yaml`
Expected: one or more lines (e.g. `global.image.repository` and/or per-component `image.repository`).

- [ ] **Step 2: Change every lakerunner default repo to ecr-public**

For each match, change `ghcr.io/cardinalhq/lakerunner` → `public.ecr.aws/cardinalhq.io/lakerunner`. Add/keep a comment: `# ecr-public default; ghcr.io/cardinalhq/lakerunner is a supported alternate`.

- [ ] **Step 3: Verify render uses ecr-public for lakerunner and ecr-public for maestro**

Run: `helm template c conductor -f conductor/tests/values-unified.yaml | grep -Eo 'image: [^ ]*(lakerunner|maestro)[^ ]*' | sort -u`
Expected: lakerunner image shows `public.ecr.aws/cardinalhq.io/lakerunner:v1.40.4`; maestro shows `public.ecr.aws/cardinalhq.io/maestro:v1.53.0`.

- [ ] **Step 4: Commit**

```bash
git add conductor/values.yaml
git commit -m "feat(conductor): default lakerunner image to ecr-public (ghcr.io as alternate)"
```

### Task 2: Add the `bootstrap:` values block + helpers

**Files:** Modify `conductor/values.yaml`, `conductor/templates/_helpers-lakerunner.tpl`

- [ ] **Step 1: Add the bootstrap values block**

Append to `conductor/values.yaml`:

```yaml
# Fresh-install bootstrap. On a fresh install the chart seeds a shared admin key
# and Maestro provisions a shared LakeRunner org at boot. On adoption set
# mode: never (sub-project C adds full auto-detection).
bootstrap:
  # auto = run the fresh-install bootstrap (seed key + render MAESTRO_BOOTSTRAP_*).
  # never = skip everything (adopt: point at existing external DB/store, no provisioning).
  # force = same as auto (reserved; C differentiates auto vs force via detection).
  mode: auto
  # The shared org Maestro provisions and that telemetry is attributed to.
  org:
    id: ""                 # UUID; REQUIRED when mode!=never. e.g. 11111111-1111-1111-1111-111111111111
    name: "default"
    ownerEmail: ""         # REQUIRED when mode!=never
  # Admin key shared by admin-api (validated from configdb) and Maestro.
  adminKey:
    # When set, use this existing Secret instead of generating one (sealed-secrets/GitOps).
    existingSecret: ""
    existingSecretKey: "admin-api-key"
  # Bucket coordinates Maestro provisions for the shared org. Mirror the object store.
  bucket:
    name: ""               # REQUIRED when mode!=never
    region: "us-east-1"
    cloudProvider: "aws"   # aws|gcp|azure
    collectorName: "default"
    endpoint: ""           # S3-compatible endpoint (rustfs/minio)
    usePathStyle: false
    insecureTls: false
```

- [ ] **Step 2: Add helpers**

Append to `conductor/templates/_helpers-lakerunner.tpl`:

```
{{/* Whether fresh-install bootstrap is active (false when mode=never). */}}
{{- define "conductor.bootstrapEnabled" -}}
{{- ne (.Values.bootstrap.mode | default "auto") "never" -}}
{{- end }}

{{/* Name of the admin-key anchor Secret (operator-supplied or chart-managed). */}}
{{- define "conductor.adminKeySecretName" -}}
{{- if .Values.bootstrap.adminKey.existingSecret -}}
{{- .Values.bootstrap.adminKey.existingSecret -}}
{{- else -}}
{{- printf "%s-admin-api-key" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/* Key name within the admin-key Secret. */}}
{{- define "conductor.adminKeySecretKey" -}}
{{- .Values.bootstrap.adminKey.existingSecretKey | default "admin-api-key" -}}
{{- end }}

{{/* In-cluster admin-api / query-api base URLs (release-scoped service names). */}}
{{- define "conductor.adminApiUrl" -}}
{{- printf "http://%s-lakerunner-admin-api:9091" .Release.Name -}}
{{- end }}
{{- define "conductor.queryApiUrl" -}}
{{- printf "http://%s-lakerunner-query-api:8080" .Release.Name -}}
{{- end }}
```

> **Verify the service names** before relying on them: run
> `helm template c conductor -f conductor/tests/values-unified.yaml | yq 'select(.kind=="Service") | .metadata.name'`
> and confirm `c-lakerunner-admin-api` and `c-lakerunner-query-api` exist with ports 9091/8080. If the admin-api Service name differs (it is colocated in control-plane — see `admin-api-service.yaml`), correct `conductor.adminApiUrl` to the actual name.

- [ ] **Step 3: Commit**

```bash
git add conductor/values.yaml conductor/templates/_helpers-lakerunner.tpl
git commit -m "feat(conductor): bootstrap values block + URL/secret helpers"
```

### Task 3: Persistent anchor admin-key Secret

**Files:** Create `conductor/templates/bootstrap/admin-key-secret.yaml`

- [ ] **Step 1: Create the Secret template (lookup-stable; skipped when existingSecret set)**

```yaml
{{- if and (include "conductor.bootstrapEnabled" .) (not .Values.bootstrap.adminKey.existingSecret) -}}
{{- $name := include "conductor.adminKeySecretName" . -}}
{{- $key := include "conductor.adminKeySecretKey" . -}}
{{- /* Reuse the existing key across upgrades so it never churns; generate only if absent.
       Pure `helm template` (no cluster) regenerates — GitOps users set bootstrap.adminKey.existingSecret. */ -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $name -}}
{{- $val := "" -}}
{{- if and $existing $existing.data (index $existing.data $key) -}}
{{- $val = index $existing.data $key -}}
{{- else -}}
{{- $val = printf "ak_%s" (randAlphaNum 48) | b64enc -}}
{{- end -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ $name }}
  labels:
    {{- include "lakerunner.labels" . | nindent 4 }}
type: Opaque
data:
  {{ $key }}: {{ $val }}
{{- end }}
```

- [ ] **Step 2: Verify it renders a stable-shaped secret**

Run: `helm template c conductor -f conductor/tests/values-unified.yaml --set bootstrap.org.id=11111111-1111-1111-1111-111111111111 --set bootstrap.org.ownerEmail=a@b.c --set bootstrap.bucket.name=b | yq 'select(.kind=="Secret" and (.metadata.name|test("admin-api-key")))'`
Expected: a Secret `c-admin-api-key` with a base64 `admin-api-key` value.

Run again with `--set bootstrap.adminKey.existingSecret=my-sec` and confirm the Secret is NOT rendered (operator-supplied).

- [ ] **Step 3: Commit**

```bash
git add conductor/templates/bootstrap/admin-key-secret.yaml
git commit -m "feat(conductor): persistent anchor admin-key Secret (lookup-stable, existingSecret override)"
```

### Task 4: migrate-lakerunner pre-install hook

**Files:** Create `conductor/templates/bootstrap/migrate-lakerunner-job.yaml`; modify the copied `conductor/templates/lakerunner/setup-job.yaml`

- [ ] **Step 1: Inspect the legacy setup-job to reuse its env/volumes**

Run: `sed -n '1,120p' conductor/templates/lakerunner/setup-job.yaml`
Note how it builds DB env (the `lakerunner.injectEnvSetup` / `lakerunner.setupEnv` helpers), service account, security contexts, and image. Reuse those helpers verbatim.

- [ ] **Step 2: Create the migration Job as a pre-install/pre-upgrade hook**

Create `conductor/templates/bootstrap/migrate-lakerunner-job.yaml` modeled on `setup-job.yaml`, but: name `{{ .Release.Name }}-migrate-lakerunner`; `helm.sh/hook: pre-install,pre-upgrade`; `helm.sh/hook-weight: "0"`; `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`; command `["/app/bin/lakerunner"]`, args `["migrate","--databases","lrdb,configdb"]`. Keep the same `serviceAccountName`, security contexts, image (`lakerunner.image`), and the setup DB env injection helper used by the legacy setup-job. Render only when `include "conductor.bootstrapEnabled" .` OR always (migrations are safe/idempotent on every install) — gate with `{{- if .Values.setup.enabled | default true }}` to preserve the legacy toggle.

- [ ] **Step 3: Neutralize the legacy setup-job's migration role**

The copied `conductor/templates/lakerunner/setup-job.yaml` also runs `setup` (migrations). To avoid double-migration, change its args from `["setup"]` to a no-op OR disable it. Simplest: delete `conductor/templates/lakerunner/setup-job.yaml` (migrations now live in the dedicated hook). Confirm nothing else references the setup job name.

Run: `grep -rn "fullname.*-setup\|run-migrations" conductor/templates/ || echo "no refs"`

- [ ] **Step 4: Verify render**

Run: `helm template c conductor -f conductor/tests/values-unified.yaml | yq 'select(.kind=="Job") | .metadata.name'`
Expected includes `c-migrate-lakerunner`; the old `c-lakerunner-setup` is gone.

- [ ] **Step 5: Commit**

```bash
git add conductor/templates/bootstrap/migrate-lakerunner-job.yaml conductor/templates/lakerunner/
git commit -m "feat(conductor): migrate-lakerunner pre-install hook (replaces setup-job migrations)"
```

### Task 5: migrate-maestro pre-install hook

**Files:** Create `conductor/templates/bootstrap/migrate-maestro-job.yaml`

- [ ] **Step 1: Find how mcp-gateway is invoked**

Run: `grep -n -A20 'define "maestro.mcpGatewaySidecar"' conductor/templates/_helpers-maestro.tpl`
Note the image, command/args, and the DB env it injects (`maestro.databaseEnv` reads `.Values.maestroDatabase`). Reuse that exact image + DB env.

- [ ] **Step 2: Create the maestro migration Job (pre-install/pre-upgrade hook)**

Create `conductor/templates/bootstrap/migrate-maestro-job.yaml`: name `{{ .Release.Name }}-migrate-maestro`; hook `pre-install,pre-upgrade`; weight `"0"`; delete-policy `before-hook-creation,hook-succeeded`; `serviceAccountName {{ include "conductor.serviceAccountName" . }}`; one container using the mcp-gateway image/command from Step 1, with env: the maestro DB env (`include "maestro.databaseEnv" .`) plus `- name: MCP_MIGRATE_ONLY` / `value: "true"`. Gate with `{{- if .Values.maestro.enabled }}`.

- [ ] **Step 3: Verify render**

Run: `helm template c conductor -f conductor/tests/values-unified.yaml | yq 'select(.kind=="Job" and .metadata.name=="c-migrate-maestro") | .spec.template.spec.containers[0].env[] | select(.name=="MCP_MIGRATE_ONLY")'`
Expected: `{name: MCP_MIGRATE_ONLY, value: "true"}`.

- [ ] **Step 4: Commit**

```bash
git add conductor/templates/bootstrap/migrate-maestro-job.yaml
git commit -m "feat(conductor): migrate-maestro pre-install hook (mcp-gateway MCP_MIGRATE_ONLY)"
```

### Task 6: key-seed post-install hook (configdb admin_api_keys upsert)

**Files:** Create `conductor/templates/bootstrap/key-seed-job.yaml`

- [ ] **Step 1: Determine configdb connection env**

Run: `grep -n -A20 'define "lakerunner.setupEnv"\|configdb' conductor/templates/_helpers-lakerunner.tpl | head -40`
Identify how configdb host/port/db/user/password are exposed (values `configdb.lrdb.*` + secret `configdb.secretName` key `CONFIGDB_PASSWORD`). The seed Job will build a libpq connection from these.

- [ ] **Step 2: Create the seed Job**

Create `conductor/templates/bootstrap/key-seed-job.yaml`:

```yaml
{{- if include "conductor.bootstrapEnabled" . -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-bootstrap-key-seed
  labels:
    {{- include "lakerunner.labels" . | nindent 4 }}
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: 6
  template:
    metadata:
      labels:
        {{- include "lakerunner.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "conductor.serviceAccountName" . }}
      restartPolicy: Never
      {{- include "lakerunner.imagePullSecrets" . | nindent 6 }}
      containers:
      - name: key-seed
        image: public.ecr.aws/docker/library/postgres:18-alpine
        command: ["/bin/sh","-ec"]
        args:
          - |
            HASH=$(printf %s "$ADMIN_KEY" | sha256sum | cut -d' ' -f1)
            echo "seeding admin key hash ${HASH%${HASH#????}}… into admin_api_keys"
            PGPASSWORD="$CONFIGDB_PASSWORD" psql \
              --set=ON_ERROR_STOP=1 \
              -h "$CONFIGDB_HOST" -p "$CONFIGDB_PORT" -U "$CONFIGDB_USER" -d "$CONFIGDB_NAME" \
              -v hash="$HASH" \
              -c "INSERT INTO admin_api_keys (key_hash, name, description) VALUES (:'hash', 'conductor-bootstrap', 'seeded by conductor bootstrap') ON CONFLICT (key_hash) DO NOTHING;"
            echo "done"
        env:
          - name: ADMIN_KEY
            valueFrom:
              secretKeyRef:
                name: {{ include "conductor.adminKeySecretName" . }}
                key: {{ include "conductor.adminKeySecretKey" . }}
          - name: CONFIGDB_HOST
            value: {{ .Values.configdb.lrdb.host | quote }}
          - name: CONFIGDB_PORT
            value: {{ .Values.configdb.lrdb.port | quote }}
          - name: CONFIGDB_NAME
            value: {{ .Values.configdb.lrdb.name | quote }}
          - name: CONFIGDB_USER
            value: {{ .Values.configdb.lrdb.username | quote }}
          - name: CONFIGDB_PASSWORD
            valueFrom:
              secretKeyRef:
                # Use the helper — the chart creates the secret release-prefixed
                # (c-lakerunner-configdb-credentials), NOT the bare values name.
                name: {{ include "lakerunner.configdbSecretName" . | quote }}
                key: {{ .Values.configdb.passwordKey | default "CONFIGDB_PASSWORD" | quote }}
{{- end }}
```

> **C-extension note:** C replaces the bare `INSERT ... ON CONFLICT DO NOTHING` with the fresh/adopt/error detection state machine (and fails the hook on `error`). B intentionally keeps it idempotent-but-dumb.

- [ ] **Step 3: Verify render**

Run: `helm template c conductor -f conductor/tests/values-unified.yaml --set bootstrap.org.id=11111111-1111-1111-1111-111111111111 --set bootstrap.org.ownerEmail=a@b.c --set bootstrap.bucket.name=b | yq 'select(.metadata.name=="c-bootstrap-key-seed") | .spec.template.spec.containers[0].args[0]'`
Expected: the script containing the `INSERT INTO admin_api_keys` upsert.

- [ ] **Step 4: Commit**

```bash
git add conductor/templates/bootstrap/key-seed-job.yaml
git commit -m "feat(conductor): post-install key-seed job (idempotent admin_api_keys upsert)"
```

### Task 7: Wire MAESTRO_BOOTSTRAP_* into the maestro deployment

**Files:** Modify `conductor/templates/maestro/maestro-deployment.yaml`

- [ ] **Step 1: Locate the maestro container env block**

Run: `grep -n 'env:\|MAESTRO_\|.Values.maestro.env' conductor/templates/maestro/maestro-deployment.yaml | head`
Identify where the maestro container's `env:` list is and how `.Values.maestro.env` is appended.

- [ ] **Step 2: Add the bootstrap env (gated on bootstrapEnabled)**

In the maestro container `env:` list, insert (indented to match siblings):

```yaml
{{- if include "conductor.bootstrapEnabled" . }}
- name: MAESTRO_BOOTSTRAP_ORG_ID
  value: {{ required "bootstrap.org.id is required when bootstrap.mode!=never" .Values.bootstrap.org.id | quote }}
- name: MAESTRO_BOOTSTRAP_ORG_NAME
  value: {{ .Values.bootstrap.org.name | default "default" | quote }}
- name: MAESTRO_BOOTSTRAP_OWNER_EMAIL
  value: {{ required "bootstrap.org.ownerEmail is required when bootstrap.mode!=never" .Values.bootstrap.org.ownerEmail | quote }}
- name: MAESTRO_BOOTSTRAP_LAKERUNNER_QUERY_API_URL
  value: {{ include "conductor.queryApiUrl" . | quote }}
- name: MAESTRO_BOOTSTRAP_LAKERUNNER_ADMIN_API_URL
  value: {{ include "conductor.adminApiUrl" . | quote }}
- name: MAESTRO_BOOTSTRAP_LAKERUNNER_ADMIN_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "conductor.adminKeySecretName" . }}
      key: {{ include "conductor.adminKeySecretKey" . }}
{{- if .Values.bootstrap.bucket.name }}
- name: MAESTRO_BOOTSTRAP_BUCKET_NAME
  value: {{ .Values.bootstrap.bucket.name | quote }}
- name: MAESTRO_BOOTSTRAP_BUCKET_REGION
  value: {{ .Values.bootstrap.bucket.region | default "us-east-1" | quote }}
- name: MAESTRO_BOOTSTRAP_BUCKET_CLOUD_PROVIDER
  value: {{ .Values.bootstrap.bucket.cloudProvider | default "aws" | quote }}
- name: MAESTRO_BOOTSTRAP_BUCKET_COLLECTOR_NAME
  value: {{ .Values.bootstrap.bucket.collectorName | default "default" | quote }}
{{- with .Values.bootstrap.bucket.endpoint }}
- name: MAESTRO_BOOTSTRAP_BUCKET_ENDPOINT
  value: {{ . | quote }}
{{- end }}
- name: MAESTRO_BOOTSTRAP_BUCKET_USE_PATH_STYLE
  value: {{ .Values.bootstrap.bucket.usePathStyle | default false | quote }}
- name: MAESTRO_BOOTSTRAP_BUCKET_INSECURE_TLS
  value: {{ .Values.bootstrap.bucket.insecureTls | default false | quote }}
{{- end }}
{{- end }}
```

- [ ] **Step 3: Verify render (bootstrap on) and absence (mode=never)**

Run: `helm template c conductor -f conductor/tests/values-unified.yaml --set bootstrap.org.id=11111111-1111-1111-1111-111111111111 --set bootstrap.org.ownerEmail=a@b.c --set bootstrap.bucket.name=lr --set bootstrap.bucket.endpoint=http://rustfs:9000 | yq 'select(.kind=="Deployment" and (.metadata.name|test("maestro$"))) | .spec.template.spec.containers[].env[] | select(.name|test("MAESTRO_BOOTSTRAP"))' | head`
Expected: the 6 core/lakerunner vars + bucket vars; the admin key via `secretKeyRef`.

Run with `--set bootstrap.mode=never` and confirm NO `MAESTRO_BOOTSTRAP_*` env appears.

- [ ] **Step 4: Lint + commit**

```bash
helm lint conductor
git add conductor/templates/maestro/maestro-deployment.yaml
git commit -m "feat(conductor): wire MAESTRO_BOOTSTRAP_* (gated on bootstrap.mode)"
```

---

## Part 2 — Scripted fresh-install test

> These live under `test/fresh-install/` (NOT shipped in the chart). They target the kubepi cluster in a dedicated namespace (see memory: kubepi adoption/fresh test bed). All commands assume `kubectl`/`helm` point at kubepi and `NS=conductor-fresh`.

### Task 8: Postgres 18 fixture

**Files:** Create `test/fresh-install/10-postgres.yaml`

- [ ] **Step 1: Write a Postgres 18 Deployment+Service+Secret+init**

Create `test/fresh-install/10-postgres.yaml`: a `Secret` (`pg-credentials`: `LRDB_PASSWORD`, `CONFIGDB_PASSWORD`, `MAESTRO_DB_PASSWORD` all set to a test value), a `ConfigMap` with an init SQL that `CREATE DATABASE lakerunner; CREATE DATABASE configdb; CREATE DATABASE maestro;` and creates matching roles, a `Deployment` using `public.ecr.aws/docker/library/postgres:18-alpine` mounting the init SQL at `/docker-entrypoint-initdb.d/`, and a `Service` `postgres:5432`. Model role/db names on `install-scripts/generated/postgres-manifests.yaml` but Postgres 18 and add the `maestro` DB.

- [ ] **Step 2: Apply and verify**

Run: `kubectl -n $NS apply -f test/fresh-install/10-postgres.yaml && kubectl -n $NS rollout status deploy/postgres --timeout=120s`
Run: `kubectl -n $NS exec deploy/postgres -- psql -U postgres -c '\l' | grep -E 'lakerunner|configdb|maestro'`
Expected: all three databases present.

- [ ] **Step 3: Commit**

```bash
git add test/fresh-install/10-postgres.yaml
git commit -m "test(fresh): Postgres 18 fixture (lakerunner/configdb/maestro DBs)"
```

### Task 9: rustfs S3 fixture + bucket

**Files:** Create `test/fresh-install/20-rustfs.yaml`

- [ ] **Step 1: Adapt rustfs manifests from conductor trial-testenv**

Run: `ls ../conductor/dev/trial-testenv/ && grep -rl rustfs ../conductor/dev/trial-testenv/`
Copy/adapt the rustfs Deployment+Service (S3 API on `:9000`, path-style, a known access/secret key) into `test/fresh-install/20-rustfs.yaml`. Add an init Job (or `mc`/`aws s3api` one-shot) that creates the bucket `lakerunner`. If trial-testenv has no standalone rustfs manifest, model it on its Helm values for the object store and pin `rustfs` image used there.

- [ ] **Step 2: Apply and verify the bucket exists**

Run: `kubectl -n $NS apply -f test/fresh-install/20-rustfs.yaml && kubectl -n $NS rollout status deploy/rustfs --timeout=120s`
Run: a one-off `aws --endpoint-url http://rustfs.$NS.svc:9000 s3 ls` (path-style, test creds) shows the `lakerunner` bucket.
Expected: bucket `lakerunner` listed.

- [ ] **Step 3: Commit**

```bash
git add test/fresh-install/20-rustfs.yaml
git commit -m "test(fresh): rustfs S3-compatible store + lakerunner bucket"
```

### Task 10: conductor fresh-install values + install

**Files:** Create `test/fresh-install/30-values.yaml`

- [ ] **Step 1: Write fresh-install values**

Create `test/fresh-install/30-values.yaml` wiring the chart to the fixtures: `database.lrdb`/`configdb.lrdb`/`maestroDatabase` → host `postgres`, the three DBs, creds from `pg-credentials`; object store (`maestro.objectStore` + lakerunner `cloudProvider`/`storageProfiles`) → endpoint `http://rustfs:9000`, bucket `lakerunner`, `usePathStyle: true`, test creds; `license` → a test license secret; `storageProfiles.yaml` with one entry for the bootstrap org id, bucket `lakerunner`, `endpoint http://rustfs:9000`, `use_path_style: true`; `pubsub.HTTP.enabled: true`; `bootstrap`: `mode: auto`, `org.id: 11111111-1111-1111-1111-111111111111`, `org.ownerEmail: admin@test.local`, `bucket.name: lakerunner`, `bucket.endpoint: http://rustfs:9000`, `bucket.usePathStyle: true`, `bucket.insecureTls: true`. Keep `ha.enabled: false`.

- [ ] **Step 2: Install and wait for rollout**

Run: `helm install conductor conductor -n $NS -f test/fresh-install/30-values.yaml`
Run: `kubectl -n $NS get jobs` — expect `conductor-migrate-lakerunner`, `conductor-migrate-maestro` (pre) completed, then `conductor-bootstrap-key-seed` (post) completed.
Run: `kubectl -n $NS rollout status deploy/conductor-maestro-maestro --timeout=300s` and the lakerunner deployments.
Expected: migrations + key-seed Jobs `Complete`; pods Ready.

- [ ] **Step 3: Verify the admin key landed in configdb and maestro provisioned**

Run: `kubectl -n $NS exec deploy/postgres -- psql -U postgres -d configdb -c 'SELECT name FROM admin_api_keys;'`
Expected: a `conductor-bootstrap` row.
Run: `kubectl -n $NS logs deploy/conductor-maestro-maestro | grep -i bootstrap | tail`
Expected: bootstrap created/þfound the shared deployment (no fatal errors).

- [ ] **Step 4: Commit**

```bash
git add test/fresh-install/30-values.yaml
git commit -m "test(fresh): conductor fresh-install values + install step"
```

### Task 11: collector fixture → telemetry into lakerunner

**Files:** Create `test/fresh-install/40-collector.yaml`, `test/fresh-install/50-send-telemetry.sh`

- [ ] **Step 1: Write the collector fixture**

Create `test/fresh-install/40-collector.yaml` from `base-collector-manifests/gateway/configmap.yaml`: a `cardinalhq-otel-collector` Deployment + Service exposing OTLP (`4317`/`4318`), config with OTLP receivers and an `awss3` exporter targeting rustfs (`endpoint http://rustfs:9000`, `region us-east-1`, `s3_bucket lakerunner`, `s3_force_path_style true`, `s3_prefix otel-raw/11111111-1111-1111-1111-111111111111/default`) and `s3uploader.notifications.endpoint: http://conductor-lakerunner-pubsub-http:8080/`. Logs/metrics/traces pipelines all export to `awss3`. Inject rustfs creds via env.

- [ ] **Step 2: Apply collector + send telemetry**

Create `test/fresh-install/50-send-telemetry.sh` that uses a telemetrygen (or `otelgen`) Job, or `curl` OTLP/HTTP, to push a known log line, a metric, and a trace span (each tagged with a recognizable attribute, e.g. `service.name=fresh-test`) to the collector's `:4318`. Then wait ~60s for the awss3 flush + pubsub notification + processing.

Run: `kubectl -n $NS apply -f test/fresh-install/40-collector.yaml && kubectl -n $NS rollout status deploy/otel-collector --timeout=120s && bash test/fresh-install/50-send-telemetry.sh`
Run: `kubectl -n $NS exec deploy/postgres -- psql -U postgres -d lakerunner -c 'SELECT count(*) FROM lakerunner_inqueue;'` (or the relevant ingest table) to confirm objects were registered.
Expected: object(s) registered for ingest; no errors in process-logs/metrics/traces logs.

- [ ] **Step 3: Commit**

```bash
git add test/fresh-install/40-collector.yaml test/fresh-install/50-send-telemetry.sh
git commit -m "test(fresh): collector fixture + telemetry emit"
```

### Task 12: Validate via query-api direct AND maestro proxy

**Files:** Create `test/fresh-install/60-validate.sh`

- [ ] **Step 1: Mint a per-user API key for the maestro proxy**

The proxy needs `X-Org-Id` + a per-user key. In `60-validate.sh`, create one by inserting a per-user API key row into the maestro DB for the bootstrap org/owner (find the table+hash via `grep -rin "api.key" ../conductor/packages/maestro/src | grep -i psk` and the proxy auth middleware), OR via any maestro admin endpoint if one exists. Capture the plaintext.

- [ ] **Step 2: Query query-api directly (org key)**

In `60-validate.sh`, get the org/admin key, then:
```bash
curl -fsS -H "x-cardinalhq-api-key: $ORG_KEY" -H 'content-type: application/json' \
  -d '{"q":"*","s":-3600000,"e":0}' \
  http://conductor-lakerunner-query-api.$NS.svc:8080/api/v1/logs/query | tee /tmp/direct.json
```
Assert the response contains the `fresh-test` data (grep for the marker attribute). Repeat for metrics and traces subpaths.

- [ ] **Step 3: Query via the maestro proxy**

```bash
INSTANCE=$(kubectl -n $NS exec deploy/postgres -- psql -U postgres -d maestro -tAc "SELECT id FROM maestro_lakerunner_deployments LIMIT 1;")
curl -fsS -H "X-Org-Id: 11111111-1111-1111-1111-111111111111" -H "X-CardinalHQ-API-Key: $USER_KEY" \
  -H 'content-type: application/json' -d '{"q":"*","s":-3600000,"e":0}' \
  http://conductor-maestro-maestro.$NS.svc:4200/api/lakerunner/$INSTANCE/query/logs/query | tee /tmp/proxy.json
```
Assert the proxy response contains the same `fresh-test` data.

- [ ] **Step 4: Make the script exit non-zero on any missing data**

The script must `grep -q` the marker in both `/tmp/direct.json` and `/tmp/proxy.json` and `exit 1` if either is missing, printing a clear PASS/FAIL summary.

- [ ] **Step 5: Commit**

```bash
git add test/fresh-install/60-validate.sh
git commit -m "test(fresh): validate query-api direct + maestro proxy return ingested data"
```

### Task 13: Orchestrator + teardown

**Files:** Create `test/fresh-install/00-run.sh`, `test/fresh-install/99-teardown.sh`

- [ ] **Step 1: Orchestrator**

`00-run.sh`: set `NS=${NS:-conductor-fresh}`; `kubectl create ns $NS`; apply 10/20; `helm install` with 30-values; wait; apply 40 + run 50; run 60; print overall PASS/FAIL and exit with 60's code.

- [ ] **Step 2: Teardown**

`99-teardown.sh`: `helm uninstall conductor -n $NS; kubectl delete ns $NS`.

- [ ] **Step 3: Full end-to-end run on kubepi**

Run: `NS=conductor-fresh bash test/fresh-install/00-run.sh`
Expected: final line `FRESH-INSTALL PASS` and exit 0 — telemetry ingested and returned by BOTH query-api direct and the maestro proxy.

- [ ] **Step 4: Commit**

```bash
git add test/fresh-install/00-run.sh test/fresh-install/99-teardown.sh
git commit -m "test(fresh): orchestrator + teardown; full e2e passes on kubepi"
```

---

## Self-review notes (spec coverage)

- Phased migrate-lakerunner / migrate-maestro(-mcp) → Tasks 4, 5 (spec §6.2). ✓
- Provision-both direct configdb key-seed (`admin_api_keys` upsert, sha256) → Task 6 (spec §6.1). ✓
- Anchor Secret (lookup-stable + existingSecret override) → Task 3 (spec §6.1). ✓
- MAESTRO_BOOTSTRAP_* wiring incl. bucket → Task 7 (spec §6.5). ✓
- ecr-public lakerunner image → Task 1 (spec §5.4). ✓
- `bootstrap.mode` knob (auto/never/force; never = adopt-safe no-render) → Tasks 2,6,7 (spec §6.6). ✓
- Fresh-install test: rustfs + Postgres 18 + collector + curl via query-api AND maestro proxy → Tasks 8–13 (spec §8.2). ✓
- Deferred to C (NOT in B): full fresh/adopt/error detection state machine + adopt-time MAESTRO_BOOTSTRAP_* gating + §8.3 failure-mode tests. Flagged in Task 6.
- Open verification the implementer must do early: exact admin-api/query-api/pubsub-http **Service names** (Task 2 Step 2) and the maestro per-user API key table/mint path (Task 12 Step 1).
```

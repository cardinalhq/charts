# Migrating a split LakeRunner + Maestro install to the unified `conductor` chart

This runbook covers adopting an existing, separately-installed `lakerunner` +
`maestro` deployment into a single `conductor` release **without provisioning or
clobbering any existing data**.

`conductor` bundles LakeRunner and Maestro into one chart. When you point a new
`conductor` release at the **same external Postgres and object store** your split
install already uses, the data is preserved — only the Kubernetes resource names
and rebuildable caches change.

> **Golden rule:** adopt with `bootstrap.mode: adopt`. In `adopt` mode conductor
> renders **no** bootstrap (no detection Job, no admin-key seed Job, no anchor
> Secret, and **no** `MAESTRO_BOOTSTRAP_*` env on the Maestro deployment). It
> simply points at the existing external DB/store and provisions nothing.

---

## 1. Prerequisites

1. **Back up Postgres.** Take a logical dump (`pg_dump`) of both the LakeRunner
   config database and the Maestro database before doing anything. Adoption does
   not write to these DBs, but a backup is your rollback safety net.
2. **Back up (or snapshot) the object store.** The S3/MinIO/rustfs bucket holding
   your lake data is the source of truth for telemetry; it is referenced, not
   recreated, by conductor.
3. **Confirm `pgvector` is available on the Maestro database.** Maestro requires
   the `vector` extension. Verify with:
   ```sql
   SELECT extname FROM pg_extension WHERE extname = 'vector';
   ```
   If absent, install it (`CREATE EXTENSION vector;`) on the Maestro DB before
   adopting.
4. **Have the suite license secret ready.** conductor uses a single license
   (`cardinal-license`) for both the LakeRunner and Maestro halves. Either supply
   the raw `license.json` via `license.create: true` + `license.data`, or
   pre-create the secret and set `license.create: false` +
   `license.secretName: cardinal-license`.
5. **Know your current external DB + object-store coordinates** (hosts, ports,
   database names, users, password secrets, bucket, endpoint).
6. **Size Postgres `max_connections` for the full unified stack.** Under one
   release the entire LakeRunner stack's pgx connection pools run alongside
   Maestro against the same Postgres. A modestly-sized Postgres can hit *too many
   clients already* (SQLSTATE `53300`) — most acutely during a rolling **upgrade**,
   when Helm/Kubernetes briefly runs roughly 2× the pods. Our live test fixture
   uses `max_connections=400`; size yours for the combined steady-state plus
   upgrade headroom (or front Postgres with **pgbouncer**, which is already part of
   the LakeRunner topology). **If you use pgbouncer, the bootstrap migration Jobs
   still need a *direct*, non-pgbouncer connection** — they take Postgres advisory
   locks to serialize schema changes, which transaction-pooled pgbouncer does not
   preserve. Point the migrate Jobs' DB host at Postgres directly even if the
   workloads go through pgbouncer.

---

## 2. Values mapping (split charts → conductor)

Most LakeRunner keys carry over unchanged. The biggest change is that the Maestro
chart's top-level `database:` block becomes conductor's **`maestroDatabase:`** so
it does not collide with LakeRunner's databases.

| Legacy location | Conductor key | Notes |
|---|---|---|
| `lakerunner` `database:` (LRDB) | `database:` | unchanged |
| `lakerunner` `configdb:` (config DB) | `configdb:` | unchanged |
| `lakerunner` `storageProfiles:` | `storageProfiles:` | unchanged; keep the same org/bucket rows |
| `lakerunner` `apiKeys:` | `apiKeys:` | unchanged; keep existing org keys |
| `lakerunner` object-store keys (bucket / endpoint / region / credentials) | same keys | point at the **same** bucket/endpoint |
| **`maestro` `database:`** | **`maestroDatabase:`** | **renamed** — host/port/name/username/password/sslMode/secretName/passwordKey |
| `lakerunner` `cardinalApiKey` / license secret | `license:` (`cardinal-license`) | one license for the whole suite |
| `maestro` license secret | `license:` (`cardinal-license`) | folded into the same single `license:` |

Maestro-specific feature config (Dex/OIDC, github-cache, mcp-gateway, etc.) maps
to the corresponding conductor `maestro.*` / top-level keys; see
`conductor/values.yaml` for the full surface.

### Example `adopt-values.yaml`

```yaml
bootstrap:
  mode: adopt            # <-- adopt an existing install; provision nothing

# LakeRunner config DB (same external Postgres as the split install)
configdb:
  lrdb:
    host: postgres.db.svc
    port: 5432
    name: config
    username: config
    sslMode: require
  # password via existing secret or configdb.lrdb.password

# LakeRunner LRDB
database:
  lrdb:
    host: postgres.db.svc
    port: 5432
    name: lrdb
    username: lakerunner
    sslMode: require

# Maestro DB — was the maestro chart's top-level `database:`
maestroDatabase:
  host: postgres.db.svc
  port: 5432
  name: maestro
  username: maestro
  sslMode: require
  secretName: pg-credentials
  passwordKey: MAESTRO_DB_PASSWORD

# One license for the whole suite
license:
  create: false
  secretName: cardinal-license

# Object store + org config — keep identical to the split install
storageProfiles:
  yaml:
    - organization_id: 22222222-2222-2222-2222-222222222222
      instance_num: 1
      collector_name: "kubepi"
      cloud_provider: "aws"
      region: "us-east-2"
      bucket: "your-existing-bucket"
      endpoint: ""
      use_path_style: true
apiKeys:
  # keep your existing org API keys
```

---

## 3. Migration steps

1. **Uninstall the legacy LakeRunner release** (Helm only removes the chart's
   Kubernetes objects; the external Postgres + object store are untouched):
   ```bash
   helm uninstall <lr-release> -n <namespace>
   ```
2. **Uninstall the legacy Maestro release:**
   ```bash
   helm uninstall <maestro-release> -n <namespace>
   ```
3. **Install conductor in `adopt` mode**, pointed at the **same** external
   Postgres + object store:
   ```bash
   helm install conductor ./conductor -n <namespace> -f adopt-values.yaml
   ```
   Wait for the rollout (`kubectl -n <namespace> rollout status ...`).

Because `mode: adopt` renders no bootstrap, conductor will not seed an admin key,
will not create a shared LakeRunner deployment in Maestro, and will not run the
detection Job — it just attaches to your existing data.

---

## 4. What changes after adoption

- **Resource names get a new prefix.** Objects are renamed to
  `<release>-lakerunner-*` and `<release>-maestro-*` (the new release name,
  e.g. `conductor-lakerunner-query-api`). This is expected — Helm tracks the new
  release; the old per-chart names are gone.
- **Caches cold-start (no data loss).** The Maestro `github-cache` StatefulSet
  PVC and the Maestro `-data` PVC are **rebuildable caches**, not your telemetry.
  Under a new release name they start empty and repopulate (github-cache
  re-clones). Your actual data lives in the external Postgres + object store and
  is untouched.
- **ServiceAccounts / secrets consolidate.** The two legacy per-chart
  ServiceAccounts and license secrets are replaced by one release-named
  ServiceAccount and a single `cardinal-license` secret.

---

## 5. Keep `mode: adopt` set for the life of the adopted release

Leave `bootstrap.mode: adopt` in your values for any release that adopted a
legacy install. Under `auto`, any populated non-conductor state — lakerunner
orgs/keys/buckets and/or a maestro org or lakerunner integration, with no
conductor-owned shared deployment present — causes the pre-install detection Job
to **abort the install** (`ADOPT_LEGACY`, or `ERROR` if only one side is
populated) rather than risk creating a duplicate shared deployment. That abort is
the safety net, not a bug — re-run with `mode: adopt`.

(`mode: force` is for recovery/testing only; it bootstraps unconditionally with
no detection safety net and can create duplicates against a populated DB. Do not
use it to adopt.)

---

## 6. Rollback

Adoption does not migrate or rewrite data, so rollback is straightforward:

1. `helm uninstall conductor -n <namespace>` (leaves external DB + object store
   intact).
2. Reinstall the original split charts pointed at the **same** external Postgres
   + object store:
   ```bash
   helm install <lr-release> ./lakerunner -n <namespace> -f <old-lr-values>.yaml
   helm install <maestro-release> ./maestro -n <namespace> -f <old-maestro-values>.yaml
   ```
3. If anything looks wrong with the data itself, restore from the `pg_dump` /
   object-store snapshot taken in step 1 of the Prerequisites.

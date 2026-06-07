# Unified LakeRunner + Maestro Helm Chart — Design

**Date:** 2026-06-05
**Status:** Draft (Codex-reviewed; all §11 decisions resolved — ready for user review)
**Branch:** `worktree-unified-chart`

## 1. Goal

Merge the separate `lakerunner` and `maestro` Helm charts into a single chart. The
two products are now considered one deployable unit. The legacy split charts will
be retired once the unified chart reaches parity and the adoption path is proven.

The unified chart must support two distinct lifecycles:

1. **Fresh install** — stand up a working LakeRunner + Maestro from nothing,
   following the "naked LakeRunner + Maestro-provisioned shared instance" pattern
   that the `lakerunner-cloudformation` stack pioneered (the desired end state).
2. **Adoption** — an operator deletes their existing split `lakerunner` and
   `maestro` Helm releases and installs the unified chart with their existing
   override values, pointed at the **same external Postgres and object store**.
   Existing data, orgs, and configuration must be left untouched.

## 2. Scope

### In scope (keep)
- All core LakeRunner data-plane and query-plane components (ingest/process,
  compact, rollup, sweeper, query-api, query-worker, control-plane, admin-api).
- Maestro API/UI, **mcp-gateway** (always-on; required component), **github-cache**
  (HA infrastructure, auto-enabled when `ha.enabled=true`), **dex/OIDC**
  (chart-native — we keep the chart's dex, not the ECS variant).
- A new bootstrap/broker mechanism that wires LakeRunner ↔ Maestro automatically.

### Out of scope (drop entirely)
- **Grafana** (deployment, service, datasource configmap) — visualization is out.
- **Bundled collector** (`collector.yaml`) as a shipped chart component. A collector
  survives only as a **fresh-install test fixture**, not a chart-installable object.
- **Perch / k8s-watcher** (clusterrole/deployment/configmap) — its LakeRunner↔Maestro
  bridging role is being replaced; it leaves with the split chart.

### Non-goals
- No bundled Postgres or object store. Both are external, exactly as today.
- No support for installing third-party observability tooling.
- No changes to the behavior of existing (adopted) installs beyond schema
  migrations, which are idempotent.

## 3. Key decisions (resolved during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Chart structure | **Single monolithic chart** | Lakerunner+maestro are one unit now. Full control over resource names/labels/ordering (matters for a customer who checks in rendered `helm template` output and reviews diffs), no value nesting, no `helm dependency build` step, clean cross-cutting glue (shared secret, bootstrap). |
| Fresh-install bootstrap | **In-cluster port of the CloudFormation pattern** via idempotent broker Job(s) | Matches the stated end-state: naked LakeRunner + Maestro provisions the shared instance. |
| Admin key model | **Secret-anchored, DB-reconciled** (see §6.1). Operator override via `existingSecret`. | LakeRunner ends up holding the key's hash (source of truth) while a durable Secret is the recoverable plaintext anchor — idempotent and crash-safe. |
| Adopt vs fresh | **Detection-driven state machine (fresh/adopt/error), no required flag.** Optional `bootstrap: auto\|force\|never` override (default `auto`). | No "install fresh then remember to change something" footgun; removing any override can never re-trigger bootstrap. |
| ServiceAccount | **Configurable; single shared SA by default, splittable into two or more.** | Customers who don't care get one SA (simple). Security-conscious customers opt into per-component SAs with narrowly-scoped Roles. Honors the single-SA preference *and* Codex's blast-radius concern. |

## 4. Verified facts about the LakeRunner binary

These shape the bootstrap design and are confirmed against `../lakerunner` source:

1. **`ADMIN_INITIAL_API_KEY` is an in-memory fallback validator, not DB-seeded.**
   admin-api accepts that key as valid **even with no DB row** (`internal/adminconfig/db.go:46-51`:
   DB lookup first, then constant-time compare against the in-memory hash).
2. **Keys are stored SHA256-hashed; random-generation paths return plaintext once.**
   `create-initial-key` (CLI) and `POST /api/v1/admin-api-keys` generate random keys
   and never re-expose plaintext; `create-initial-key` also fails if any key exists.
   → We do **not** rely on capturing a one-time random key.
3. **A plaintext-import/upsert path for admin keys exists.** `importAdminAPIKeys()` /
   `UpsertAdminAPIKey` (`internal/bootstrap/import.go:195-211`) hashes a *caller-chosen*
   plaintext and UPSERTs by hash — idempotent and re-runnable. (Org keys have an
   analogous HTTP import at `POST /api/v1/organizations/{id}/api-keys/import`.)
4. **No advisory lock guards key creation** (`cmd/admin_api.go:143-202`,
   `admin/admin_api_keys.go:37-78`). → The broker must serialize its own mutations.
5. **Admin keys are naked/global/no-org** (`lrconfig_admin_api_keys`); org keys require
   an org. → "Naked LakeRunner, just a key, no orgs" = one admin key, zero orgs.
6. **`lakerunner setup` runs migrations only** (idempotent); org/storage seeding is the
   separate `initialize`/import path.

### Verified facts about persistent state (de-risks adoption)
- **maestro's `-data` PVC holds rebuildable working data** ("ephemeral working data:
  orchestra artifact… falls back to in-memory artifact store"); in HA it must be off
  (artifacts go to S3). **github-cache PVCs are warm git mirror caches** (rebuildable
  by re-clone). The **precious state — orgs, config, telemetry — is all external**
  (Postgres + object store). → delete-then-reinstall loses only rebuildable caches.

## 5. Architecture

### 5.1 Chart layout (monolithic)

```
chart/
  Chart.yaml            # unified name/version; appVersion tracks both images
  values.yaml           # one merged, flat values surface
  templates/
    _helpers.tpl        # merged helpers, one label/name scheme
    serviceaccount.yaml # one shared SA by default; per-component SAs opt-in
    rbac.yaml           # Role/RoleBindings scoped per effective SA
    secrets/            # db, object-store, license, admin-key anchor
    lakerunner/         # LR workloads
    maestro/            # maestro, mcp-gateway, github-cache, dex, ingress
    bootstrap/          # migration phase + broker/provision Job(s) — §6
    NOTES.txt
```

### 5.2 Shared resources
- **External Postgres**, one instance, three logical DBs: `lrdb`, `configdb`
  (LakeRunner), `maestro` (Maestro). Values supply host/creds; chart does not create
  the server.
- **External object store** (S3-compatible). Values supply bucket/endpoint/creds.
- **Admin-key anchor Secret** — durable, the plaintext source of truth for the
  bootstrap credential (see §6.1).

### 5.3 Values surface
Flat, monolithic. A migration guide ships a values-mapping note for adopters
concatenating their two override files onto the unified keys.

### 5.4a Values-contract changes from the merge (migration-guide inputs)
Discovered while building sub-project A; adopters' override files must account for these:
- **maestro DB config moved `database:` → `maestroDatabase:`.** The two charts had
  incompatible `database:` schemas (lakerunner `database.lrdb.{host,...}` nested + flat
  `secretName/create/passwordKey`; maestro `database.{host,...}` flat with different
  values). Resolution: lakerunner's `database:` stays canonical; maestro's DB config is
  namespaced as `maestroDatabase:` (rendered maestro DB wiring is byte-identical to
  legacy — only the values key moved). Adopters with maestro `database:` overrides must
  rename them to `maestroDatabase:`.
- **Single shared `license:` block** (one CardinalHQ suite license for both products,
  matching the CF `cardinal-license` end-state). Default `license.secretName` =
  `cardinal-license`. Adopters who kept separate per-product license secrets, or a
  differently-named one, set `license.secretName` (+ `license.create:false`) to point at
  their existing secret. **RESOLVED (user confirmed):** one shared suite license is
  correct; the chart ships a single `license:` block (default secret `cardinal-license`).
- **Known future-dedup debt (not defects; deferred):** duplicate `license-validation`
  hooks (one per family validating the same block), duplicate `cardinal-api-key` secrets
  (one per family, identical data), and large near-duplicate `_helpers-*.tpl` families.
  Candidates for consolidation in a later sub-project once parity/adoption are proven.

### 5.4 Image registries
Per the updated `lakerunner-cloudformation` reference (`cardinal-defaults.yaml`,
`image_manifest.py`), the standard is **100% `public.ecr.aws/cardinalhq.io/*` for all
Cardinal-owned images** (lakerunner, maestro, dex-customization, otel-collector),
SHA-pinned, with third-party images mirrored on ecr-public
(`public.ecr.aws/docker/library/postgres:18-alpine`, `public.ecr.aws/aws-cli/...`).
**ecr-public is the default; ghcr.io is the documented alternate.** The unified chart
should default Cardinal images to ecr-public for consistency.
- **RESOLVED (user confirmed):** unify the lakerunner default to
  `public.ecr.aws/cardinalhq.io/lakerunner`, keeping ghcr.io as a documented override.
  Applied as a deliberate, reviewed values change **in sub-project B** (kept out of A so
  A's render-parity stayed clean).

## 6. Bootstrap — phased, not one monolithic hook

Codex review rejected stuffing migrations + classification + credential minting +
provisioning into a single `post-install` hook that races workload/admin-api
readiness. Bootstrap is therefore split into **ordered phases** with explicit
serialization. All phases are idempotent and driven by durable state.

### 6.0 Serialization & ordering
- A single **DB advisory lock** (LakeRunner already uses advisory locks for
  migrations) OR a Kubernetes **Lease** serializes all bootstrap mutations, so
  concurrent Helm syncs / Job retries / GitOps double-applies cannot race.
- Phases run in order via Helm hook weights (pre-install/pre-upgrade for migrations
  and key reconcile; post-install/post-upgrade for provisioning). Each phase
  validates both sides of state before acting.
- **Rollback:** bootstrap Jobs must not run schema-assuming or destructive logic on
  `helm rollback`; migrations are forward-only and gated on detected schema version.

### 6.1 Admin-key model — CHOSEN: provision-both seeds configdb directly
The "provision-both" broker step already needs DB access to both databases (for
detection), so it seeds the admin key by a **direct, idempotent SQL upsert into
LakeRunner's configdb** — no missing LakeRunner CLI, no cross-repo change, and
LakeRunner still owns the key (its hash lives in configdb). "Choose once, done."

1. **Anchor the plaintext once.** Broker ensures a durable Secret holds the admin-key
   plaintext: if `adminKey.existingSecret` is set, use it (operator-supplied,
   sealed-secrets/GitOps path); else generate a random `ak_<hex>` and create the Secret
   lookup-or-create (atomic; a losing concurrent creator reads the winner's).
2. **Seed the hash into configdb directly.** Compute `key_hash = sha256(plaintext)` (hex)
   and upsert into the `admin_api_keys` table (current name — the `lrconfig_` prefix was
   removed by migration `1755713265`). DDL: `(id UUID default gen_random_uuid() PK,
   key_hash TEXT NOT NULL UNIQUE, name TEXT NOT NULL, description, created_at default
   now())`. SQL: `INSERT INTO admin_api_keys (key_hash, name, description) VALUES (...)
   ON CONFLICT (key_hash) DO NOTHING;`. Idempotent on the unique hash.
   `admin-api ValidateAPIKey` hashes any presented key the same way and looks it up —
   no key-format requirement — so the chosen plaintext is accepted.
3. Maestro receives the same plaintext via `MAESTRO_BOOTSTRAP_..._ADMIN_API_KEY`
   (from the anchor Secret); it stores it in its `maestro_lakerunner_deployments` row
   (same unprotected-in-maestro-DB state as today, per user) and uses it to call
   admin-api, which now accepts it.

Crash-idempotent in every order: the anchor Secret is created before anything depends
on it; the configdb upsert is idempotent on the hash; re-runs no-op.

> **Documented coupling:** the broker takes a schema dependency on the `admin_api_keys`
> table. If that schema drifts, the broker's SQL must change. Escape hatch: add a
> `lakerunner` CLI command to drive `internal/bootstrap` `UpsertAdminAPIKey` and have
> the broker call that instead. Acceptable for now (user-confirmed "most direct").
> The in-memory `ADMIN_INITIAL_API_KEY` fallback remains available as a belt-and-
> suspenders but is not the primary mechanism.

### 6.2 Migration phases (pre-workload) — two ordered jobs
Per user's "migrate-lakerunner, migrate-maestro(-mcp), provision both" model:
- **migrate-lakerunner:** `lakerunner migrate --databases lrdb,configdb` (golang-migrate
  handles its own locking; idempotent; safe on populated/adopted DBs).
- **migrate-maestro:** mcp-gateway image with `MCP_MIGRATE_ONLY=true` — runs maestro DB
  migrations (`gomigrate_maestro`, golang-migrate) and exits 0. This is the supported
  migrate-only mode; it avoids multiple maestro replicas auto-migrating concurrently.
Both run as pre-install/pre-upgrade hook Jobs (ordered via hook weights) before app pods
that depend on the schema start.

### 6.3 Detection / classification phase
Read durable state and classify (see §7). Output a clear status (configmap/Job log)
so operators can see *why* fresh/adopt/error was chosen.

### 6.4 Provisioning phase (fresh only)
Maestro, via `MAESTRO_BOOTSTRAP_*`, provisions the shared LakeRunner deployment + org +
storage, authenticating to in-cluster admin-api with the anchor key. **Verified: the
Maestro app already decouples this from admin-api readiness** — bootstrap writes a DB
row (no admin-api call at startup), then an **async provisioning worker retries with
exponential backoff** (`1s,2s,4s,8s,16s`, ≤6 attempts) and treats 5xx/network errors as
retryable; a failure logs-and-continues (find-or-create idempotent on every boot). So
**no dedicated provisioning Job and no readiness gate are required** — the chart only
sets the env (§6.5). admin-api's `POST /api/v1/provision` is itself idempotent (upsert).
Chart detail: point the admin-api readiness probe at **`/readyz`** (gates on DB
connectivity), not `/healthz` (which goes 200 before DBs connect).

### 6.5 Maestro wiring (net-new in Helm)
```
MAESTRO_BOOTSTRAP_LAKERUNNER_QUERY_API_URL = http://<query-api-svc>:8080
MAESTRO_BOOTSTRAP_LAKERUNNER_ADMIN_API_URL = http://<admin-api-svc>:9091
MAESTRO_BOOTSTRAP_LAKERUNNER_ADMIN_API_KEY = <from anchor Secret>
MAESTRO_BOOTSTRAP_BUCKET_*                  = shared object-store coordinates
```

### 6.6 Bootstrap override knob
`bootstrap: auto|force|never` (default `auto`): `auto` = detection-driven (safe
default); `force` = always attempt provisioning (testing/recovery); `never` = never
provision. Because `auto` is self-correcting against DB state, an operator may set
`never` for a first adopt install, then **delete the line** — `auto` keeps skipping
because state is now populated. Removing the knob can never re-trigger bootstrap.

## 7. Adoption semantics & detection state machine

Detection is a **state machine**, not a coarse "DB has rows ⇒ adopt" (which Codex
correctly flagged as misclassifying partial/failed installs):

- **fresh** — all relevant DBs are schema-current **and empty** of orgs/keys, and no
  Maestro↔LakeRunner integration exists. → mint anchor + provision.
- **adopt** — a valid existing Maestro LakeRunner integration/deployment exists *and*
  points at consistent LakeRunner state. → skip minting + skip provisioning.
- **error** — mixed/partial states (e.g. Maestro populated but `configdb` wiped;
  anchor Secret present but no DB key; admin keys present from legacy `initialize`
  with no Maestro integration). → **fail loudly** with a documented recovery path;
  never silently choose fresh or adopt.

Why detection is mandatory, not cosmetic: the legacy standalone Maestro never used
`MAESTRO_BOOTSTRAP_*`; it learned about LakeRunner via a UI-configured integration in
its DB. An adopted install already has a hand-made shared deployment, so blind
bootstrap would create a duplicate. Detection prevents this.

Determinism for GitOps: bootstrap manifests are always rendered; only runtime behavior
branches on state. Rendered manifests stay a pure function of values — detection only
ever *prevents* a mutation, never silently *causes* one.

### Migration path
Delete the split `lakerunner` + `maestro` releases, then install the unified chart
with override values pointed at the same external Postgres + object store + secrets.
Detection lands in **adopt** and no-ops all provisioning.
- **PVCs:** all at-risk PVCs (maestro `-data`, github-cache) are rebuildable
  caches/scratch; precious state is external (§4). Migration guide still recommends a
  Postgres/object-store backup beforehand, and notes github-cache **cold-starts**
  (re-clones mirrors) after adoption.

## 8. Testing

### 8.1 Adoption test (kubepi cluster, dedicated namespace)
1. Install legacy split charts, healthy, with external-equivalent PG + object store.
2. Configure a LakeRunner integration in Maestro the old (UI) way → populate the DB.
3. `helm uninstall` both legacy releases.
4. `helm install` the unified chart with equivalent overrides.
5. **Assert:** services come up; detection → **adopt**; no duplicate orgs/deployments;
   existing data/queries still work; github-cache cold-start completes.

### 8.2 Fresh-install test (scripted, self-contained)
- **Fixtures:** object store via **rustfs** (S3-compatible), **Postgres 18+**, a
  **collector** fixture emitting logs/metrics/traces.
- **Install:** unified chart, self-hosted mode, empty DBs → bootstrap anchors key +
  provisions.
- **Validation (curl-level acceptable for now):** (1) collector sends logs+metrics+
  traces; (2) `query-api` returns it **directly** (curl); (3) the **same query via the
  Maestro proxy path** returns it (curl) — proving provisioning + proxy route work;
  (4) stretch: Maestro UI Explore shows it.

The `../conductor` SaaS sandbox is a structural model only — customers do **not**
install SaaS mode (`MAESTRO_DEPLOYMENT_MODE=saas` gates trial/license UX). The test
runs **self-hosted**.

### 8.3 Failure-mode acceptance tests (Codex-required before "adoption proven")
- Broker crash after DB key reconcile but before Maestro reads the anchor.
- Anchor-Secret/DB-key mismatch (e.g. sealed-secret changed after DB key existed).
- Two concurrent bootstrap Jobs / GitOps double-sync (serialization holds).
- `helm rollback` after an upgrade (no schema-assuming bootstrap re-run).
- Populated Maestro + wiped `configdb` (and the inverse) → classified **error**, not a
  silent fresh/adopt.
- Missing/renamed PVC after adoption → cold-start path verified, no data loss.
The broker emits a status summary (fresh/adopt/error + reason) for observability.

## 9. Decomposition & build order

Each sub-project gets its own spec → plan → implementation cycle:

- **(A) Unified chart skeleton** — monolithic layout, merged helpers/labels,
  SA(s)+RBAC (per §11), drop grafana/collector/perch. *Exit:* `helm template`/`lint`
  render parity with the two legacy charts for equivalent values (minus dropped).
- **(B) Fresh-install bootstrap** — phased migration + key anchor/reconcile +
  `MAESTRO_BOOTSTRAP_*` wiring + serialization; plus the §8.2 fresh-install test.
  *Exit:* fresh-install test passes end-to-end. **Depends on** the Maestro-bootstrap
  resilience prerequisite (§11).
- **(C) Adoption path** — detection state machine, `bootstrap` knob, migration guide +
  values mapping; plus §8.1 + §8.3 tests. *Exit:* adoption + failure-mode tests pass.
- **(D) Dex / OIDC consolidation** — settle chart-native dex into the unified chart.

Suggested order: **A → B → C → D** (D can overlap once maestro templates land in A).

## 10. Risks

- **Maestro DB migrations on adopt** must be forward-only and safe against a populated
  maestro DB; the migration phase must prevent multi-replica concurrent auto-migrate.
- **Admin-key lifecycle.** The anchor key is a high-value global admin credential.
  Need a documented rotation flow (ensure new key → update Secret → roll Maestro →
  verify → revoke old) and compromise/sealed-secret-mismatch behavior. Open whether
  Maestro can use a least-privileged credential post-bootstrap instead of global admin.
- **RBAC union** correctness once SAs/Roles are finalized (§11).

## 11. Open decisions (need user input)

1. **ServiceAccount split — RESOLVED.** Configurable, with a **single shared SA as the
   default** (broker + lakerunner + maestro all use it; its Role is the union of needed
   perms) — simplest for customers who don't care. Operators who want least-privilege
   **opt into per-component SAs** (e.g. a narrow `bootstrap` SA with Secret-write + DB,
   a `controlPlane` SA with deployment-scale rights, a `maestro` SA); when a component
   names its own SA it gets a narrowly-scoped Role, else it uses the shared union SA.
   RBAC templates are structured so each component's Role binds to its *effective* SA.
2. **Admin-key model — RESOLVED: primary** (§6.1: Secret-anchored *and* DB-reconciled
   via `UpsertAdminAPIKey`, so LakeRunner owns the hash).
3. **Maestro-bootstrap resilience — RESOLVED: no gap.** Verified against `../conductor`
   (maestro source) and `../lakerunner`: maestro bootstrap writes a DB row and never
   calls admin-api at startup; an async provisioning worker retries with exponential
   backoff and treats 5xx/network errors as retryable; failures log-and-continue,
   idempotent every boot. admin-api `/api/v1/provision` is idempotent (upsert). The
   chart only sets `MAESTRO_BOOTSTRAP_*` and probes admin-api at `/readyz`. No app
   change and no issue filed.

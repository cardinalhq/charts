# Unified LakeRunner + Maestro Helm Chart — Design

**Date:** 2026-06-05
**Status:** Draft (Codex-reviewed; 2 decisions open for user — see §11)
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
| ServiceAccount | **OPEN — see §11.** Leaning: one SA for steady-state workloads + a separate, narrowly-scoped bootstrap SA. | User wanted one SA; Codex flagged blast-radius. Compromise honors both. |

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
    serviceaccount.yaml # SAs (count TBD — §11)
    rbac.yaml           # Role/RoleBindings (scoped per SA)
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

### 6.1 Admin-key model (Secret-anchored, DB-reconciled)
Chosen to eliminate the unrecoverable-crash failure mode (capturing a one-time random
plaintext) and to make LakeRunner the durable owner:

1. **Anchor the plaintext once.** Broker ensures a durable Secret holding the admin
   key plaintext: if `adminKey.existingSecret` is set, use it (operator-supplied,
   sealed-secrets/GitOps path); else generate a random value and create the Secret
   with lookup-or-create (atomic; a losing concurrent creator reads the winner's).
2. **Reconcile the DB hash from the anchor.** Feed that plaintext through the existing
   `UpsertAdminAPIKey` import path → configdb stores the hash (LakeRunner = source of
   truth). Deterministic: re-running re-hashes the same plaintext → same hash → no-op.
3. admin-api validates the key from configdb (with the in-memory env fallback as a
   belt-and-suspenders). Maestro reads the plaintext from the anchor Secret.

This is crash-idempotent in every order: Secret-but-no-DB-row → re-import; the anchor
is created before anything depends on it, so plaintext is never lost.

> **Alternative (simpler, if import wiring proves awkward):** skip step 2 and inject
> the anchor value as `ADMIN_INITIAL_API_KEY` into admin-api (in-memory fallback,
> no DB row) **and** as `MAESTRO_BOOTSTRAP_..._ADMIN_API_KEY` into Maestro — exactly
> the CloudFormation shape. Trade-off: the key lives only in the Secret, not in
> LakeRunner's DB. Recorded as the fallback in §11.

### 6.2 Migration phase (pre-workload)
Run LakeRunner (`lrdb`,`configdb`) and Maestro DB migrations as a dedicated phase
**before** app pods that depend on the schema start. One runner per DB; never let
multiple Maestro replicas auto-migrate concurrently. Idempotent and safe on populated
(adopted) DBs.

### 6.3 Detection / classification phase
Read durable state and classify (see §7). Output a clear status (configmap/Job log)
so operators can see *why* fresh/adopt/error was chosen.

### 6.4 Provisioning phase (fresh only)
Maestro, via `MAESTRO_BOOTSTRAP_*`, provisions the shared LakeRunner deployment + org
+ storage, authenticating to in-cluster admin-api with the anchor key. Because Maestro
bootstrap runs at process start, it **must tolerate admin-api readiness delays** (retry
/ backoff) — this is a hard prerequisite on the Maestro app (§11). If the app's
bootstrap is not resilient to admin-api being down, provisioning moves into a dedicated
Job that waits for admin-api readiness instead of relying on pod start order.

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

- **MAESTRO_BOOTSTRAP_* app contract** is unproven in Helm (exists only in the ECS
  reference). Pin exact env names, retry-on-admin-api-down behavior, restart
  idempotency, and skip/fail logging before implementing B (§11 prerequisite).
- **Maestro DB migrations on adopt** must be forward-only and safe against a populated
  maestro DB; the migration phase must prevent multi-replica concurrent auto-migrate.
- **Admin-key lifecycle.** The anchor key is a high-value global admin credential.
  Need a documented rotation flow (ensure new key → update Secret → roll Maestro →
  verify → revoke old) and compromise/sealed-secret-mismatch behavior. Open whether
  Maestro can use a least-privileged credential post-bootstrap instead of global admin.
- **RBAC union** correctness once SAs/Roles are finalized (§11).

## 11. Open decisions (need user input)

1. **ServiceAccount split.** You wanted one normalized SA ("open to not, if enterprisey
   reasons"). Codex's enterprisey reason: the broker needs **Secret-mutation** rights
   and elevated DB access that no steady-state pod should carry, and LakeRunner
   control-plane needs deployment-scale rights Maestro doesn't.
   **Recommendation:** one normalized SA for steady-state workloads **+** a separate,
   narrowly-scoped **bootstrap SA** (Secret write + DB). Optionally keep
   control-plane's scaling RBAC on its own SA. Your call on how far to split.
2. **Admin-key model.** §6.1 primary (Secret-anchored *and* DB-reconciled via
   `UpsertAdminAPIKey`, so LakeRunner owns the hash) vs the §6.1 alternative
   (Secret-only via `ADMIN_INITIAL_API_KEY` fallback, no DB row — simpler, matches
   CloudFormation, but key not stored in LakeRunner). Recommendation: primary.
3. **Maestro-bootstrap resilience prerequisite.** Implementing B cleanly assumes
   Maestro's `MAESTRO_BOOTSTRAP_*` flow retries when admin-api isn't ready yet. If the
   Maestro app doesn't already do this, we either fix it app-side or move provisioning
   into a readiness-gated Job. Needs confirmation against the Maestro source.

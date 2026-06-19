# Conductor Re-converge (Foundation Phase) — Design

**Date:** 2026-06-19
**Status:** Draft (awaiting user review)
**Branch:** `feat/conductor-reconverge`

## 1. Goal

The unified `conductor` chart has drifted from the standalone `lakerunner` and
`maestro` charts it was vendored from. Conductor was last synced on 2026-06-07
(PR #198, commit `67ac8da`) at lakerunner v1.41.x / maestro v1.53.1; the
standalone charts have since advanced ~16 releases each to **lakerunner v1.57.1
(chart 3.16.8)** and **maestro v1.64.0 (chart 0.9.23)**.

Bring conductor back to parity with the current standalone charts, unpin its
stale image tags, and **prove a fresh install Just Works end-to-end** against the
existing `test/fresh-install` harness on the `kubepi` cluster.

This is the **foundation** for retiring the split charts. Per the agreed
direction: once conductor can replace the production install (via a later
one-time migration), the split model is dropped and conductor becomes the sole
chart. That migration and the split-chart retirement are **out of scope here**.

## 2. Context & constraints

- **Monolithic design is retained** (per the 2026-06-05 unified-chart design,
  §3): conductor vendors lakerunner + maestro templates into
  `templates/lakerunner/` and `templates/maestro/`, with a `templates/bootstrap/`
  glue layer and shared `templates/shared/` SA+RBAC. Subchart/umbrella and
  codegen approaches were rejected — there is no point depending on or
  generating from charts that are about to be deleted.
- **Split charts remain the source of truth** for the LR/maestro halves until
  cutover. Conductor tracks them; they do not track conductor.
- **External infra only.** "Just Works" means: operator supplies external
  Postgres + S3-compatible object store + license; the chart bootstraps schema,
  admin key, and provisioning. No bundled Postgres/object store in the chart
  (the test harness supplies them as fixtures).
- **No CI added** in this phase (decided: split charts retiring soon; rely on
  this re-converge + manual discipline).

## 3. Divergence survey (measured)

Most vendored templates are **byte-identical** to current standalone. The drift
that needs reconciling, by file:

**lakerunner** (`templates/lakerunner/`):
- `configdb-secret.yaml`, `postgresql-secret.yaml`, `storageprofile-configmap.yaml`
- `control-plane-deployment.yaml` (conductor adds a stale `autoscalerEnv`; standalone
  reworked autoscaling to `global.autoscaling.mode hpa|worklane`)
- `process-logs-deployment.yaml`, `deprecation-warnings.yaml`
- `_helpers-lakerunner.tpl` (conductor +84 lines vs standalone)

**maestro** (`templates/maestro/`):
- `maestro-deployment.yaml` — largest: standalone renamed `persistence.*`/`data`
  volume → `temporaryStorage.*`/`scratch`; conductor adds the
  `MAESTRO_BOOTSTRAP_*` env block gated on `conductor.bootstrapEnabled` (KEEP).
- `maestro-pvc.yaml`, `secret.yaml`, `dex-deployment.yaml`,
  `github-cache-statefulset.yaml`, `_helpers-maestro.tpl`

**chart-level:**
- `values.yaml` — image tags pinned to v1.41.6 / v1.53.1; missing new standalone
  keys (e.g. `temporaryStorage`, `autoscaling.mode`).
- **Missing template:** conductor has no `process-hpa.yaml`, but standalone now
  defaults `global.autoscaling.mode: hpa`. Without it conductor won't autoscale.
  Must be added with the conductor transform.

**Intentionally dropped (must stay dropped):** grafana (`grafana-*`), bundled
`collector.yaml`, perch (`perch-*`), and `setup-job.yaml`.

## 4. Reconcile method — three-way merge per file

The drift is **bidirectional** (conductor is ahead in glue, behind in upstream
evolution), so a blind copy-from-standalone would regress conductor's wiring.
For each vendored file, perform a three-way merge:

- **base** = standalone template tree at commit `67ac8da` (last conductor sync)
- **theirs** = current standalone (`main`: lakerunner v1.57.1 / maestro v1.64.0)
- **ours** = current conductor vendored copy

Rule: **absorb** standalone evolution (`theirs` vs `base`) while **preserving**
every conductor transform (`ours` vs `base`):
- subdir layout (`templates/lakerunner/`, `templates/maestro/`)
- helper namespacing (`_helpers-lakerunner.tpl`, `_helpers-maestro.tpl`)
- bootstrap wiring (`conductor.bootstrapEnabled`, `MAESTRO_BOOTSTRAP_*`,
  admin-key secret refs, `conductor.queryApiUrl`/`adminApiUrl` includes)
- dropped components (grafana/collector/perch/setup-job)
- conductor image defaults (ecr-public)

Byte-identical files are no-ops. Each reconciled file is verified to still render
(`helm template`) and to keep its conductor-specific hunks.

## 5. Image versioning

LR and maestro have distinct appVersions but conductor has a single nominal
`appVersion`. Pin per-family explicitly in `values.yaml`:
- lakerunner image tag → `v1.57.1`
- maestro image tag → `v1.64.0`

Bump conductor chart version `0.1.0 → 0.2.0`. Update the `appVersion` comment in
`Chart.yaml` to the new nominal pair.

## 6. Verification (in order)

1. `helm lint conductor`
2. `helm template conductor` with each of `conductor/tests/values-{lakerunner,maestro,unified}.yaml`
3. `conductor/tests/render-parity.sh conductor/tests/values-lakerunner.yaml
   conductor/tests/values-maestro.yaml conductor/tests/values-unified.yaml`
   — expected LEGACY-ONLY = grafana/collector/perch resources + the 2 legacy
   ServiceAccounts + legacy scaler Role/RoleBinding; expected UNIFIED-ONLY = one
   release-named SA/Role/RoleBinding. No other diffs.
4. `NS=conductor-fresh bash test/fresh-install/00-run.sh` on `kubepi` →
   **`FRESH-INSTALL PASS`** (collector → rustfs → pubsub-http → process-* →
   queryable via query-api direct AND maestro proxy).

## 7. Out of scope (follow-ups)

- One-time prod migration / adoption script and split-chart retirement.
- Adoption (`test/adoption`) and failure-mode (`test/failure-modes`) test runs.
- CI drift-guard.

## 8. Risks

- **values.yaml + helpers merges are the riskiest** (largest, most logic). The
  three-way merge plus `helm template`/lint after each contains this.
- **New standalone templates.** Confirmed (`comm` against `67ac8da`):
  `process-hpa.yaml` is the *only* template added to standalone since vendoring
  (lakerunner side; none on maestro side). It must be vendored in with the
  conductor transform. No other hidden additions.
- **Fresh-install env coupling.** The harness requires the `kubepi` context
  (available) and the sibling `conductor` repo for license minting (present at
  `/Users/mgraff/git/github/cardinalhq/conductor`). Postgres needs `pgvector`;
  the fixture already provides it.

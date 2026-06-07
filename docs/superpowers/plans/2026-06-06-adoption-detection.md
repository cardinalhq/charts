# Adoption Path + Detection State Machine (Sub-project C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `conductor` safely collapse an existing split lakerunner+maestro install into one release — detect fresh vs adopt vs error and never clobber or duplicate existing data — with a migration guide and live adoption + failure-mode tests.

**Architecture:** A `mode=auto` **pre-install detection Job** queries configdb + the maestro DB, classifies the install (fresh / adopt-conductor / adopt-legacy / error), and **exits non-zero to abort the helm install** when it would be unsafe (legacy/foreign state under `auto`, or inconsistent state) — so nothing is ever silently clobbered and maestro never starts to create a duplicate. `mode=adopt` renders **no** bootstrap (no detection, key-seed, anchor Secret, or `MAESTRO_BOOTSTRAP_*`) and simply points at the existing external DB/store. `mode=force` bootstraps unconditionally (recovery). Fresh and conductor's-own-reinstall under `auto` are idempotent.

**Tech Stack:** Helm, Go templates, `psql` (postgres:18-alpine), bash, kubectl; legacy charts `lakerunner@3.13.6` + `maestro@0.8.21` for the adoption test.

**Builds on B:** B shipped `bootstrap.mode` (auto/never/force), the anchor Secret (normal resource), pre-install migrate hooks, post-install key-seed, and `MAESTRO_BOOTSTRAP_*`. C **renames `never`→`adopt`** (keeps `never` as a hidden alias), adds the detection Job, refines render gates, and adds tests.

**Mode semantics (final):**
| mode | detection job | key-seed + anchor + MAESTRO_BOOTSTRAP_* | meaning |
|---|---|---|---|
| `auto` (default) | yes (pre-install) | rendered | detect; fresh→bootstrap, adopt-conductor→idempotent skip, legacy/error→ABORT |
| `adopt` (alias `never`) | no | NOT rendered | point at existing external DB/store; no provisioning |
| `force` | no | rendered | bootstrap unconditionally (recovery/testing) |

**Detection signals (verified):**
- configdb (lakerunner): `SELECT count(*) FROM organizations`, `... admin_api_keys`, `... organization_buckets`.
- maestro: `SELECT count(*) FROM maestro_organizations`; legacy lakerunner integration `SELECT count(*) FROM maestro_integrations WHERE type='lakerunner' AND deployment_id IS NULL`; conductor's shared deployment (must match maestro's `listSharedAutoAddEnabled`): `SELECT count(*) FROM maestro_lakerunner_deployments WHERE source='shared_cardinal' AND enabled AND is_demo=false AND auto_add_to_all_orgs AND btrim(coalesce(admin_api_url,''))<>'' AND btrim(coalesce(admin_api_key,''))<>''`.

**Classifier (the core logic).** Safe rule: under `auto`, bootstrap ONLY when conductor
already owns the shared deployment (idempotent) OR everything is truly empty (fresh);
**abort on any other populated/partial state** (operator must choose `adopt` or `force`).
This guarantees "never clobber/duplicate; fail loudly."
```
# configdb (lakerunner)
LR_BUCKETS   = count(organization_buckets); LR_ORGS = count(organizations); LR_KEYS = count(admin_api_keys)
# maestro
M_SHARED = count(maestro_lakerunner_deployments WHERE shared_cardinal eligible)   # == maestro listSharedAutoAddEnabled
M_ORGS   = count(maestro_organizations); M_LEGACY = count(maestro_integrations WHERE type='lakerunner' AND deployment_id IS NULL)

LR_STATE = (LR_BUCKETS>0 OR LR_ORGS>0 OR LR_KEYS>0)
M_STATE  = (M_ORGS>0 OR M_LEGACY>0)

classify:
  if M_SHARED>0                      -> ADOPT_CONDUCTOR  (exit 0: idempotent; key-seed no-ops; maestro skips)
  elif not LR_STATE and not M_STATE  -> FRESH            (exit 0: seed + provision)
  elif LR_STATE and M_STATE          -> ADOPT_LEGACY     (exit 1 abort: "set bootstrap.mode=adopt")
  else                               -> ERROR            (exit 1 abort: only one side populated — inconsistent)
```
Note: `admin_api_keys` and `maestro_integrations`-alone are now part of the populated
signals, so legacy/partial states never slip through as FRESH. The FRESH branch requires
BOTH sides empty.

---

## File Structure

```
conductor/
  values.yaml                                  # mode enum doc: auto|adopt|force (never=alias)
  templates/_helpers-lakerunner.tpl            # conductor.bootstrapMode (normalize never->adopt), conductor.bootstrapEnabled, conductor.detectionEnabled
  templates/bootstrap/detect-job.yaml          # NEW: pre-install/pre-upgrade detection+classify (mode=auto only)
docs/
  conductor-migration-guide.md                 # NEW: split→single adoption runbook + values mapping
test/adoption/                                 # NEW: live kubepi adoption + auto-abort tests
  00-run.sh  10-legacy-install.sh  20-populate-legacy.sh  30-uninstall-legacy.sh
  40-adopt-install.sh  50-assert-adopt.sh  60-assert-auto-aborts.sh  99-teardown.sh
test/failure-modes/                            # NEW: §8.3 acceptance tests
  run.sh  (crash-mid-seed, secret/db-mismatch, concurrent, rollback, wiped-configdb, pvc-cold-start)
```

---

## Part 1 — Mode refinement + detection job

### Task 1: Normalize the mode enum (auto|adopt|force; never=alias)

**Files:** Modify `conductor/values.yaml`, `conductor/templates/_helpers-lakerunner.tpl`

- [ ] **Step 1: Update the values doc**

In `conductor/values.yaml` `bootstrap.mode`, change the comment to enumerate `auto` (default; detect), `adopt` (skip all bootstrap; point at existing external DB/store), `force` (bootstrap unconditionally). Note `never` is a deprecated alias of `adopt`.

- [ ] **Step 2: Add a normalizing helper**

Append to `conductor/templates/_helpers-lakerunner.tpl`:
```
{{/* Normalize bootstrap.mode; "never" is a deprecated alias of "adopt". */}}
{{- define "conductor.bootstrapMode" -}}
{{- $m := .Values.bootstrap.mode | default "auto" -}}
{{- if eq $m "never" -}}adopt{{- else -}}{{ $m }}{{- end -}}
{{- end }}

{{/* Bootstrap resources render unless adopting. */}}
{{- define "conductor.bootstrapEnabled" -}}
{{- if ne (include "conductor.bootstrapMode" .) "adopt" -}}true{{- end -}}
{{- end }}

{{/* Detection job renders only in auto mode (force skips the safety net; adopt renders nothing). */}}
{{- define "conductor.detectionEnabled" -}}
{{- if eq (include "conductor.bootstrapMode" .) "auto" -}}true{{- end -}}
{{- end }}
```
Then DELETE the old `conductor.bootstrapEnabled` define from B (the one that branched on `!= "never"`) so only this one remains.

- [ ] **Step 3: Verify the three modes gate correctly**

Run for each of `auto`,`adopt`,`force`,`never`:
`helm template c conductor -f conductor/tests/values-unified.yaml --set bootstrap.org.id=11111111-1111-1111-1111-111111111111 --set bootstrap.org.ownerEmail=a@b.c --set bootstrap.bucket.name=b --set bootstrap.mode=MODE | yq 'select(.kind=="Job") | .metadata.name' | sort`
Expected: `auto` → migrate jobs + detect + key-seed; `force` → migrate + key-seed (no detect); `adopt`/`never` → migrate jobs only (no detect, no key-seed); and `MAESTRO_BOOTSTRAP_*`/anchor Secret present for auto/force, absent for adopt/never.

- [ ] **Step 4: Commit**

```bash
git add conductor/values.yaml conductor/templates/_helpers-lakerunner.tpl
git commit -m "feat(conductor): mode auto|adopt|force (never alias) + detection/bootstrap gates"
```

### Task 2: Pre-install detection + classify Job

**Files:** Create `conductor/templates/bootstrap/detect-job.yaml`

- [ ] **Step 1: Create the detection Job (mode=auto only)**

Create `conductor/templates/bootstrap/detect-job.yaml`: a `pre-install,pre-upgrade` hook, `helm.sh/hook-weight: "1"` (after migrations at 0, before key-seed which is post-install), delete-policy `before-hook-creation,hook-succeeded`, gated `{{- if include "conductor.detectionEnabled" . }}`. Image `public.ecr.aws/docker/library/postgres:18-alpine`. It connects to BOTH configdb (`.Values.configdb.lrdb.*` + secret) and the maestro DB (`.Values.maestroDatabase.*` + secret), runs the classifier, prints the classification, and `exit 1` on ADOPT_LEGACY or ERROR. Use this script body:

```sh
set -eu
q() { PGPASSWORD="$2" PGSSLMODE="$7" psql -tA -v ON_ERROR_STOP=1 -h "$3" -p "$4" -U "$5" -d "$6" -c "$1"; }
LR_BUCKETS=$(q "SELECT count(*) FROM organization_buckets;" "$CONFIGDB_PASSWORD" "$CONFIGDB_HOST" "$CONFIGDB_PORT" "$CONFIGDB_USER" "$CONFIGDB_NAME" "$CONFIGDB_SSLMODE")
LR_ORGS=$(q    "SELECT count(*) FROM organizations;"        "$CONFIGDB_PASSWORD" "$CONFIGDB_HOST" "$CONFIGDB_PORT" "$CONFIGDB_USER" "$CONFIGDB_NAME" "$CONFIGDB_SSLMODE")
LR_KEYS=$(q    "SELECT count(*) FROM admin_api_keys;"       "$CONFIGDB_PASSWORD" "$CONFIGDB_HOST" "$CONFIGDB_PORT" "$CONFIGDB_USER" "$CONFIGDB_NAME" "$CONFIGDB_SSLMODE")
M_ORGS=$(q     "SELECT count(*) FROM maestro_organizations;" "$MDB_PASSWORD" "$MDB_HOST" "$MDB_PORT" "$MDB_USER" "$MDB_NAME" "$MDB_SSLMODE")
M_SHARED=$(q   "SELECT count(*) FROM maestro_lakerunner_deployments WHERE source='shared_cardinal' AND enabled AND is_demo=false AND auto_add_to_all_orgs AND btrim(coalesce(admin_api_url,''))<>'' AND btrim(coalesce(admin_api_key,''))<>'';" "$MDB_PASSWORD" "$MDB_HOST" "$MDB_PORT" "$MDB_USER" "$MDB_NAME" "$MDB_SSLMODE")
M_LEGACY=$(q   "SELECT count(*) FROM maestro_integrations WHERE type='lakerunner' AND deployment_id IS NULL;" "$MDB_PASSWORD" "$MDB_HOST" "$MDB_PORT" "$MDB_USER" "$MDB_NAME" "$MDB_SSLMODE")
echo "signals: lr_buckets=$LR_BUCKETS lr_orgs=$LR_ORGS lr_keys=$LR_KEYS m_orgs=$M_ORGS m_shared=$M_SHARED m_legacy=$M_LEGACY"
LR_STATE=0; { [ "$LR_BUCKETS" -gt 0 ] || [ "$LR_ORGS" -gt 0 ] || [ "$LR_KEYS" -gt 0 ]; } && LR_STATE=1
M_STATE=0;  { [ "$M_ORGS" -gt 0 ] || [ "$M_LEGACY" -gt 0 ]; } && M_STATE=1
if [ "$M_SHARED" -gt 0 ]; then echo "ADOPT_CONDUCTOR: shared deployment present — idempotent, proceeding"; exit 0; fi
if [ "$LR_STATE" -eq 0 ] && [ "$M_STATE" -eq 0 ]; then echo "FRESH: proceeding with bootstrap"; exit 0; fi
if [ "$LR_STATE" -eq 1 ] && [ "$M_STATE" -eq 1 ]; then
  echo "ADOPT_LEGACY: existing non-conductor install detected. Re-run with bootstrap.mode=adopt to adopt it without provisioning."; exit 1; fi
echo "ERROR: inconsistent state — only one of lakerunner/configdb or maestro is populated. Investigate; use bootstrap.mode=adopt or force to override."; exit 1
```
(Env also provides `CONFIGDB_SSLMODE`/`MDB_SSLMODE` from each DB's `.sslMode | default "require"`.)

Env: `CONFIGDB_*` from `.Values.configdb` (mirror the key-seed Job's env, incl. `PGSSLMODE` from `.Values.configdb.lrdb.sslMode`); `MDB_*` from `.Values.maestroDatabase` (host/port/name/user + password via `secretKeyRef` to `include "maestro.databaseSecretName" .`, plus `PGSSLMODE` from `.Values.maestroDatabase.sslMode`). Use `serviceAccountName: {{ include "conductor.serviceAccountName" . }}`, `restartPolicy: Never`, `backoffLimit: 0` (a classification failure must abort, not retry).

> Confirm the maestro DB env helper names first: `grep -n 'maestro.databaseSecretName\|maestro.databaseEnv' conductor/templates/_helpers-maestro.tpl` and reuse the exact secret name + password key.

- [ ] **Step 2: Verify it renders only under auto and queries both DBs**

Run: `helm template c conductor -f conductor/tests/values-unified.yaml --set bootstrap.org.id=11111111-1111-1111-1111-111111111111 --set bootstrap.org.ownerEmail=a@b.c --set bootstrap.bucket.name=b --set bootstrap.mode=auto | yq 'select(.metadata.name=="c-bootstrap-detect") | .spec.template.spec.containers[0].args[0]'`
Expected: the classifier script. With `--set bootstrap.mode=adopt` and `=force`: no `c-bootstrap-detect` Job.

- [ ] **Step 3: Lint + commit**

```bash
helm lint conductor
git add conductor/templates/bootstrap/detect-job.yaml
git commit -m "feat(conductor): pre-install detection job (fresh/adopt/error classifier, aborts on unsafe)"
```

---

## Part 2 — Migration guide

### Task 3: Write the split→single migration guide

**Files:** Create `docs/conductor-migration-guide.md`

- [ ] **Step 1: Write the runbook**

Create `docs/conductor-migration-guide.md` covering, concretely: (1) prerequisites — back up Postgres + object store; confirm maestro DB has `pgvector`; have the suite license secret; (2) the values mapping table — legacy `lakerunner` values → conductor keys (unchanged `database:`/`configdb:`), legacy `maestro` `database:` → conductor **`maestroDatabase:`**, both licenses → one `license:` (`cardinal-license`), object store keys; (3) the steps: `helm uninstall <lr>`; `helm uninstall <maestro>`; `helm install conductor conductor -f adopt-values.yaml` with **`bootstrap.mode: adopt`** pointed at the SAME external Postgres + object store; (4) what changes — resource names become `<release>-lakerunner-*`/`<release>-maestro-*` (new release name), github-cache + maestro `-data` PVCs **cold-start** (rebuildable caches; data is external), legacy SAs/secrets replaced by one release-named SA + `cardinal-license`; (5) note that `mode=adopt` should remain set for an adopted legacy install (under `auto`, detection will deliberately abort a legacy-shaped DB to avoid creating a duplicate shared deployment); (6) rollback — reinstall the split charts pointed at the same external DB/store.

- [ ] **Step 2: Commit**

```bash
git add docs/conductor-migration-guide.md
git commit -m "docs(conductor): split→single migration guide + values mapping"
```

---

## Part 3 — Live adoption test (kubepi)

> Namespace `conductor-adopt`, context-pinned `--context kubepi`. Reuses B's Postgres/rustfs fixtures (`test/fresh-install/10-postgres.yaml`, `20-rustfs.yaml`) and license-mint approach.

### Task 4: Install + populate the legacy split stack

**Files:** Create `test/adoption/10-legacy-install.sh`, `test/adoption/20-populate-legacy.sh`

- [ ] **Step 1: Legacy install script**

`10-legacy-install.sh`: create ns `conductor-adopt`; apply the shared Postgres 18 (pgvector) + rustfs fixtures; `helm install lr ./lakerunner --version-pin 3.13.6` and `helm install ms ./maestro` (legacy charts at repo root) with minimal external-DB values (DB host `postgres`, the lr/config/maestro DBs, rustfs object store + a `storageProfiles`/`apiKeys` entry for org `22222222-2222-2222-2222-222222222222`, the suite license). Wait for the legacy `lr-lakerunner-setup` job + rollouts.

- [ ] **Step 2: Populate maestro the legacy (UI) way via direct DB insert**

`20-populate-legacy.sh`: since the legacy maestro↔lakerunner integration is a pure UI step, simulate it with psql into the maestro DB — insert a `maestro_organizations` row and a `maestro_integrations` row `(type='lakerunner', deployment_id NULL, credentials jsonb with the lakerunner api key, org_id=...)`. This produces the ADOPT_LEGACY signal shape.

Run both; verify: `kubectl --context kubepi -n conductor-adopt exec deploy/postgres -- psql -U postgres -d maestro -c "SELECT type,deployment_id FROM maestro_integrations;"` shows the legacy lakerunner integration; configdb has `organizations`/`organization_buckets` rows.

- [ ] **Step 3: Commit**

```bash
git add test/adoption/10-legacy-install.sh test/adoption/20-populate-legacy.sh
git commit -m "test(adopt): legacy split install + legacy maestro integration fixture"
```

### Task 5: Uninstall legacy, adopt with conductor, assert no duplication

**Files:** Create `test/adoption/30-uninstall-legacy.sh`, `40-adopt-install.sh`, `50-assert-adopt.sh`

- [ ] **Step 1: Uninstall legacy**

`30-uninstall-legacy.sh`: `helm uninstall lr ms -n conductor-adopt`; wait for pods gone; (external Postgres + rustfs remain).

- [ ] **Step 2: Adopt-install conductor**

`40-adopt-install.sh`: `helm install conductor ./conductor -n conductor-adopt -f <adopt-values>` with `bootstrap.mode=adopt`, DB/store pointed at the SAME `postgres`/`rustfs`, `maestroDatabase` → the maestro DB, `license` → cardinal-license. Wait for rollout.

- [ ] **Step 3: Assert adoption correctness**

`50-assert-adopt.sh`: assert (a) all conductor pods Ready; (b) **no new bootstrap occurred** — `SELECT count(*) FROM maestro_lakerunner_deployments WHERE source='shared_cardinal';` is still 0 (adopt didn't create one), and the legacy `maestro_integrations` row is intact and singular (no duplicate); (c) configdb org/bucket counts unchanged from pre-adoption; (d) existing data still queryable via query-api with the legacy org key. Exit non-zero on any mismatch.

- [ ] **Step 4: Commit**

```bash
git add test/adoption/30-uninstall-legacy.sh test/adoption/40-adopt-install.sh test/adoption/50-assert-adopt.sh
git commit -m "test(adopt): uninstall legacy + adopt-install conductor + assert no duplication"
```

### Task 6: Assert `auto` aborts on the legacy DB (safety net)

**Files:** Create `test/adoption/60-assert-auto-aborts.sh`, `00-run.sh`, `99-teardown.sh`

- [ ] **Step 1: Auto-abort assertion**

`60-assert-auto-aborts.sh`: against the SAME legacy-populated DBs, attempt `helm install conductor-auto ./conductor -n conductor-adopt -f <values> --set bootstrap.mode=auto` and assert it **fails** and the detect Job logs `ADOPT_LEGACY`. (Clean up the failed release.) This proves the safety net prevents accidental duplication when the operator forgets `mode=adopt`.

- [ ] **Step 2: Orchestrator + teardown**

`00-run.sh`: ns setup → 10 → 20 → (snapshot counts) → 30 → 40 → 50 → 60 → print `ADOPTION PASS`/exit code. `99-teardown.sh`: `kubectl delete ns conductor-adopt`.

- [ ] **Step 3: Full run on kubepi**

Run: `bash test/adoption/00-run.sh`
Expected: `ADOPTION PASS` — conductor adopts the legacy install with no duplication, AND `auto` correctly aborts on the legacy-shaped DB.

- [ ] **Step 4: Commit**

```bash
git add test/adoption/
git commit -m "test(adopt): auto-abort safety-net assertion + orchestrator; passes on kubepi"
```

---

## Part 4 — Failure-mode acceptance tests (§8.3)

### Task 7: Failure-mode tests

**Files:** Create `test/failure-modes/run.sh`

- [ ] **Step 1: Implement the cases**

`test/failure-modes/run.sh` (kubepi, throwaway ns `conductor-fail`), each asserting the expected safe behavior:
1. **wiped-configdb / split-brain:** maestro populated (orgs) but configdb empty → `auto` detect classifies ERROR/ADOPT_LEGACY and aborts (no partial bootstrap).
2. **secret/DB mismatch:** anchor Secret holds key X but configdb has a different hash → maestro can't auth; assert maestro's retry surfaces a clear auth error (does not crashloop the whole release) and re-running key-seed reconciles.
3. **concurrent bootstrap:** apply two key-seed Jobs concurrently → `ON CONFLICT DO NOTHING` keeps exactly one row (no error).
4. **helm rollback:** upgrade then `helm rollback` → migrations are not re-run destructively; release stays healthy.
5. **PVC cold-start:** after adoption, github-cache StatefulSet re-clones (no data loss; eventually Ready).
Each case prints PASS/FAIL; script exits non-zero if any fail.

- [ ] **Step 2: Run on kubepi**

Run: `bash test/failure-modes/run.sh`
Expected: all cases PASS.

- [ ] **Step 3: Commit**

```bash
git add test/failure-modes/
git commit -m "test(failure-modes): split-brain/mismatch/concurrent/rollback/pvc-coldstart acceptance"
```

---

## Self-review notes (spec coverage)

- Detection state machine fresh/adopt/error → Tasks 1–2 (spec §7). ✓
- Adopt-time gating of MAESTRO_BOOTSTRAP_* (mode=adopt renders nothing; auto aborts on legacy) → Tasks 1,2,6. ✓
- Migration guide + values mapping → Task 3 (spec §5.4a, §7). ✓
- kubepi split→single adoption test → Tasks 4–6 (spec §8.1). ✓
- §8.3 failure-mode tests → Task 7. ✓
- "Set adopt once, fail-safe, never clobber" (user requirement) → detection ABORTS rather than clobbers; documented that adopt stays set for legacy installs (Task 3 step 5). ✓
- Reuses B fixtures (Postgres18/rustfs/license-mint) rather than duplicating. ✓
- Open verification for the implementer: exact `maestro.databaseSecretName`/password key (Task 2 Step 1); legacy chart install values against external DB (Task 4 — crib from `install-scripts/generated/`).
```

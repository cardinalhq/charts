# Unified Chart Skeleton (Sub-project A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a single monolithic Helm chart `conductor/` that renders the same in-scope resources as the legacy `lakerunner` + `maestro` charts combined, minus grafana/collector/perch, with one shared ServiceAccount by default.

**Architecture:** Vendor both charts' templates into one chart under `templates/lakerunner/`, `templates/maestro/`, and `templates/shared/`. Keep the two namespaced helper families (`lakerunner.*`, `maestro.*`) side by side — they don't collide as template names. Decouple each family's `name` from `.Chart.Name` (pin to `"lakerunner"`/`"maestro"`) so existing resource names and selector labels are preserved and pods don't cross-select. Merge `values.yaml` into one document. No bootstrap/adoption logic in this sub-project (that's B/C).

**Tech Stack:** Helm 3, Go templating. "Tests" = `helm lint` + `helm template` render-parity diffs against the legacy charts.

**Naming rules (per user):**
- Chart name / dir = **`conductor`**. The chart name appears ONLY in the `helm.sh/chart` label (not a selector label) — it is deliberately NOT injected into resource names.
- Workload/Service/etc. names stay `<release>-lakerunner-*` and `<release>-maestro-*` — the release ("named install") is the only prefix; `conductor` never appears in a resource name.
- The single shared ServiceAccount is named after the release (`.Release.Name`), not the chart, for the same reason.

**Live-copy note:** Tasks copy the current `lakerunner/` and `maestro/` template + values files verbatim, so recent image bumps (maestro nginx `1.31-alpine`, openssl `3.5.6`, etc.) are inherited automatically — do not hardcode tags.

**Reference paths:**
- Legacy: `lakerunner/`, `maestro/` (repo root)
- New: `conductor/`

---

## File Structure

```
conductor/
  Chart.yaml
  values.yaml                       # merged from lakerunner + maestro values (dropped components removed)
  .helmignore
  templates/
    _helpers-lakerunner.tpl         # copy of lakerunner/templates/_helpers.tpl + name pin + SA repoint
    _helpers-maestro.tpl            # copy of maestro/templates/_helpers.tpl + name pin + SA repoint
    shared/
      serviceaccount.yaml           # ONE shared SA (replaces both legacy SAs)
      rbac.yaml                     # union Role + RoleBinding bound to the shared SA
    lakerunner/                     # all in-scope lakerunner templates (grafana*/collector/perch* dropped)
    maestro/                        # all maestro templates (legacy serviceaccount.yaml dropped)
```

Subdirectories under `templates/` are flattened by Helm; they exist only to avoid filename collisions and aid readability.

---

## Task 1: Scaffold the `conductor` chart

**Files:**
- Create: `conductor/Chart.yaml`
- Create: `conductor/.helmignore`

- [ ] **Step 1: Create the chart directory and Chart.yaml**

```bash
mkdir -p conductor/templates/shared conductor/templates/lakerunner conductor/templates/maestro conductor/tests
```

Create `conductor/Chart.yaml`:

```yaml
apiVersion: v2
name: conductor
description: Unified Helm chart for CardinalHQ LakeRunner + Maestro
type: application
version: "0.1.0"
# appVersion is nominal only — component image tags are pinned per-component in values.yaml
# (both lakerunner.* and maestro.* image helpers would otherwise default the tag to this).
appVersion: "v1.53.0"
keywords:
  - lakerunner
  - maestro
  - logs
  - metrics
  - traces
  - observability
home: https://docs.cardinalhq.io/lakerunner
maintainers:
  - name: Cardinal HQ
    email: support@cardinalhq.com
```

- [ ] **Step 2: Create .helmignore**

```bash
cp lakerunner/.helmignore conductor/.helmignore
```

- [ ] **Step 3: Verify the chart is recognized**

Run: `helm lint conductor 2>&1 | head` — Expected: complaints about empty values/templates, but `conductor` is recognized as a chart (no "Chart.yaml file is missing").

- [ ] **Step 4: Commit**

```bash
git add conductor/Chart.yaml conductor/.helmignore
git commit -m "feat(conductor): scaffold unified chart skeleton"
```

---

## Task 2: Vendor and adapt the helper files

**Files:**
- Create: `conductor/templates/_helpers-lakerunner.tpl` (from `lakerunner/templates/_helpers.tpl`)
- Create: `conductor/templates/_helpers-maestro.tpl` (from `maestro/templates/_helpers.tpl`)

- [ ] **Step 1: Copy both helper files verbatim**

```bash
cp lakerunner/templates/_helpers.tpl conductor/templates/_helpers-lakerunner.tpl
cp maestro/templates/_helpers.tpl    conductor/templates/_helpers-maestro.tpl
```

- [ ] **Step 2: Pin `lakerunner.name` to a fixed base (preserve names + selector identity)**

In `conductor/templates/_helpers-lakerunner.tpl`, replace the body of `lakerunner.name`:

Old:
```
{{- define "lakerunner.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
```
New:
```
{{- define "lakerunner.name" -}}
{{- default "lakerunner" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
```

Also in `lakerunner.fullname`, change `{{- $name := default .Chart.Name .Values.nameOverride }}` to `{{- $name := default "lakerunner" .Values.nameOverride }}`.

- [ ] **Step 3: Pin `maestro.name` to a fixed base**

In `conductor/templates/_helpers-maestro.tpl`, replace the body of `maestro.name`:

Old:
```
{{- define "maestro.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
```
New:
```
{{- define "maestro.name" -}}
{{- default "maestro" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}
```

Also in `maestro.fullname`, change `{{- $name := default .Chart.Name .Values.nameOverride }}` to `{{- $name := default "maestro" .Values.nameOverride }}`.

> Note: a single top-level `nameOverride`/`fullnameOverride` is now ambiguous across two families; the merged values.yaml (Task 6) leaves both unset → `<release>-lakerunner` / `<release>-maestro`. Per-component renaming is a future follow-up, not in scope.

- [ ] **Step 4: Verify the helper files parse**

Run: `helm template t conductor 2>&1 | head` — Expected: errors will be about missing required values (DB host, etc.) or no resources yet, NOT a `.tpl` parse/syntax error. A template parse error must be fixed before continuing.

- [ ] **Step 5: Commit**

```bash
git add conductor/templates/_helpers-lakerunner.tpl conductor/templates/_helpers-maestro.tpl
git commit -m "feat(conductor): vendor helper families, pin name bases to preserve identity"
```

---

## Task 3: Single shared ServiceAccount + RBAC

**Files:**
- Create: `conductor/templates/shared/serviceaccount.yaml`
- Create: `conductor/templates/shared/rbac.yaml`
- Modify: `conductor/templates/_helpers-lakerunner.tpl` (add shared helper + repoint `lakerunner.serviceAccountName`)
- Modify: `conductor/templates/_helpers-maestro.tpl` (repoint `maestro.serviceAccountName`)

- [ ] **Step 1: Add a shared SA-name helper (release-named, no chart prefix)**

Append to `conductor/templates/_helpers-lakerunner.tpl`:

```
{{/*
Shared ServiceAccount name for the unified chart. Single SA by default, named
after the release (the "named install") — the chart name is intentionally NOT
injected. Override with .Values.serviceAccount.name. Per-component SAs
(least-privilege) are a future opt-in; for the skeleton every workload uses this one.
*/}}
{{- define "conductor.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (.Release.Name | trunc 63 | trimSuffix "-") .Values.serviceAccount.name -}}
{{- else -}}
{{- .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}
```

- [ ] **Step 2: Repoint both family SA helpers at the shared one**

In `conductor/templates/_helpers-lakerunner.tpl`, replace the `lakerunner.serviceAccountName` body:
```
{{- define "lakerunner.serviceAccountName" -}}
{{- include "conductor.serviceAccountName" . -}}
{{- end }}
```

In `conductor/templates/_helpers-maestro.tpl`, replace the `maestro.serviceAccountName` body:
```
{{- define "maestro.serviceAccountName" -}}
{{- include "conductor.serviceAccountName" . -}}
{{- end }}
```

- [ ] **Step 3: Create the shared ServiceAccount template**

Create `conductor/templates/shared/serviceaccount.yaml`:
```yaml
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "conductor.serviceAccountName" . }}
  labels:
    {{- include "lakerunner.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
```

- [ ] **Step 4: Create the union Role + RoleBinding**

First read the live lakerunner Role rules (maestro has no Role, so these ARE the full union):

```bash
cat lakerunner/templates/role.yaml
```

Create `conductor/templates/shared/rbac.yaml`, pasting the `rules:` content from the command above verbatim into the marked spot:

```yaml
{{- if .Values.serviceAccount.create -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "conductor.serviceAccountName" . }}
  labels:
    {{- include "lakerunner.labels" . | nindent 4 }}
rules:
  # <-- paste the rules: list from lakerunner/templates/role.yaml here, verbatim -->
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "conductor.serviceAccountName" . }}
  labels:
    {{- include "lakerunner.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "conductor.serviceAccountName" . }}
subjects:
  - kind: ServiceAccount
    name: {{ include "conductor.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
{{- end }}
```

(If the legacy `role.yaml` itself wraps rules in conditionals/`if`, preserve those conditionals exactly. The intent is byte-equivalent rules.)

- [ ] **Step 5: Commit**

```bash
git add conductor/templates/_helpers-lakerunner.tpl conductor/templates/_helpers-maestro.tpl conductor/templates/shared/
git commit -m "feat(conductor): single shared ServiceAccount + union RBAC (release-named)"
```

---

## Task 4: Copy in-scope lakerunner templates (drop grafana/collector/perch)

**Files:**
- Create: `conductor/templates/lakerunner/*.yaml` (in-scope subset)

- [ ] **Step 1: Copy every lakerunner template except dropped ones, helpers, and the replaced SA/role**

```bash
for f in lakerunner/templates/*.yaml; do
  base=$(basename "$f")
  case "$base" in
    grafana-*.yaml|collector.yaml|perch-*.yaml|serviceaccount.yaml|role.yaml) ;; # DROP / replaced
    *) cp "$f" "conductor/templates/lakerunner/$base" ;;
  esac
done
ls conductor/templates/lakerunner/
```

Expected `ls` to EXCLUDE: `grafana-datasources-configmap.yaml`, `grafana-deployment.yaml`, `grafana-service.yaml`, `collector.yaml`, `perch-clusterrole.yaml`, `perch-collectors-clusterrole.yaml`, `perch-collectors-role.yaml`, `perch-configmap.yaml`, `perch-deployment.yaml`, `serviceaccount.yaml`, `role.yaml`.

- [ ] **Step 2: Find any references to dropped components that would break rendering**

Run: `grep -rln "perch\|grafana\|collector" conductor/templates/lakerunner/` — For each hit, open it and confirm it's only an incidental mention (comment/label), not a hard dependency that breaks `helm template`. Hard breaks get fixed here; dangling values are cleaned in Task 6.

- [ ] **Step 3: Commit**

```bash
git add conductor/templates/lakerunner/
git commit -m "feat(conductor): in-scope lakerunner templates (drop grafana/collector/perch)"
```

---

## Task 5: Copy maestro templates

**Files:**
- Create: `conductor/templates/maestro/*.yaml` and `conductor/templates/NOTES.txt`

- [ ] **Step 1: Copy every maestro template except helpers and the replaced SA**

```bash
for f in maestro/templates/*.yaml; do
  base=$(basename "$f")
  case "$base" in
    serviceaccount.yaml) ;; # replaced by shared SA
    *) cp "$f" "conductor/templates/maestro/$base" ;;
  esac
done
cp maestro/templates/NOTES.txt conductor/templates/NOTES.txt
ls conductor/templates/maestro/
```

- [ ] **Step 2: Commit**

```bash
git add conductor/templates/maestro/ conductor/templates/NOTES.txt
git commit -m "feat(conductor): add maestro templates (drop legacy SA)"
```

---

## Task 6: Build the merged values.yaml

**Files:**
- Create: `conductor/values.yaml`

- [ ] **Step 1: Concatenate the two live values files as a starting point**

```bash
{ echo '# Unified conductor chart values (merged from lakerunner + maestro)'; \
  echo '# === lakerunner ==='; cat lakerunner/values.yaml; \
  echo; echo '# === maestro ==='; cat maestro/values.yaml; } > conductor/values.yaml
```

- [ ] **Step 2: Collapse duplicate top-level keys into one each**

Both charts define top-level `global:`, `serviceAccount:`, `nameOverride`, `fullnameOverride`. YAML last-wins would silently drop the earlier copy. Manually merge so exactly ONE of each remains: one `global:` (union of both charts' global keys), and this `serviceAccount:` block:

```yaml
serviceAccount:
  create: true
  name: ""        # empty → conductor.serviceAccountName uses the release name
  annotations: {}
nameOverride: ""
fullnameOverride: ""
```

Run: `grep -nE '^(global|serviceAccount|nameOverride|fullnameOverride):' conductor/values.yaml` — Expected: exactly one line per key.

- [ ] **Step 3: Remove values for dropped components**

Delete the `grafana:`, `collector:`, and `perch:` top-level blocks.

Run: `grep -nE '^(grafana|collector|perch):' conductor/values.yaml` — Expected: no output.

- [ ] **Step 4: Pin per-component image tags (don't rely on the single appVersion)**

Read the legacy effective image tags:
```bash
helm template lr lakerunner -f lakerunner/tests/$(ls lakerunner/tests | head -1) 2>/dev/null | grep -Eo 'image: [^ ]*lakerunner[^ ]*' | sort -u
helm template ms maestro -f maestro/tests/$(ls maestro/tests | head -1) 2>/dev/null | grep -Eo 'image: [^ ]*maestro[^ ]*' | sort -u
```
In `conductor/values.yaml`, set the lakerunner component image tag(s) and maestro's top-level `image.tag` to the observed versions explicitly, so neither defaults to the single `Chart.appVersion`.

- [ ] **Step 5: Lint**

Run: `helm lint conductor` — Expected: `1 chart(s) linted, 0 chart(s) failed`. Fix any stray reference to a removed value.

- [ ] **Step 6: Commit**

```bash
git add conductor/values.yaml
git commit -m "feat(conductor): merged values (one global/SA, drop grafana/collector/perch, pin tags)"
```

---

## Task 7: Render-parity verification against the legacy charts

**Files:**
- Create: `conductor/tests/render-parity.sh`
- Create: `conductor/tests/values-lakerunner.yaml`, `conductor/tests/values-maestro.yaml`, `conductor/tests/values-unified.yaml`

- [ ] **Step 1: Create minimal test values**

Inspect the legacy fixtures for the minimum required fields:
```bash
ls lakerunner/tests/ maestro/tests/
```
Create `conductor/tests/values-lakerunner.yaml` and `conductor/tests/values-maestro.yaml` from the smallest passing legacy fixtures, and `conductor/tests/values-unified.yaml` by merging the two (mirroring the values.yaml merge: one `global`/`serviceAccount`, both products' required fields).

- [ ] **Step 2: Write the parity script**

Create `conductor/tests/render-parity.sh`:
```bash
#!/usr/bin/env bash
# Renders legacy lakerunner+maestro and unified conductor with equivalent values,
# normalizes incidental differences, and compares the resource (kind,name) sets.
set -euo pipefail
REL="conductor-test"
OUT=$(mktemp -d)
LR_VALUES="${1:?lakerunner test values}"; MS_VALUES="${2:?maestro test values}"; UNI_VALUES="${3:?unified test values}"
norm() { sed -E 's#helm\.sh/chart: [^ ]+##'; }
helm template "$REL" lakerunner -f "$LR_VALUES" | norm > "$OUT/legacy-lr.yaml"
helm template "$REL" maestro    -f "$MS_VALUES" | norm > "$OUT/legacy-ms.yaml"
helm template "$REL" conductor  -f "$UNI_VALUES" | norm > "$OUT/unified.yaml"
idx() { grep -E '^(kind|  name):' "$@" | sort -u; }
idx "$OUT/legacy-lr.yaml" "$OUT/legacy-ms.yaml" > "$OUT/legacy-index.txt"
idx "$OUT/unified.yaml" > "$OUT/unified-index.txt"
echo "### diff (legacy combined vs unified) — '<' only on legacy, '>' only on unified:"
diff "$OUT/legacy-index.txt" "$OUT/unified-index.txt" || true
echo "### Expected legacy-only ('<'): grafana, collector, perch resources + the 2 legacy ServiceAccounts."
echo "### Expected unified-only ('>'): one release-named ServiceAccount/Role/RoleBinding."
echo "OUT=$OUT"
```
```bash
chmod +x conductor/tests/render-parity.sh
```

- [ ] **Step 3: Run parity and confirm the diff is only the expected deltas**

Run: `conductor/tests/render-parity.sh conductor/tests/values-lakerunner.yaml conductor/tests/values-maestro.yaml conductor/tests/values-unified.yaml`
Expected: the only differences are the dropped grafana/collector/perch resources and the SA consolidation (two legacy SAs → one release-named SA + Role/RoleBinding). No other in-scope resource missing.

- [ ] **Step 4: Resolve any duplicate-resource-name conflicts**

Run: `helm template conductor-test conductor -f conductor/tests/values-unified.yaml >/dev/null && echo OK`
If it errors on a duplicate resource name (likely the shared `license` Secret or `cardinal-api-key` Secret rendered by both families), dedupe: keep one definition and point the other family's `*SecretName` helper/reference at it. Re-run until `OK`.

- [ ] **Step 5: Commit**

```bash
git add conductor/tests/
git commit -m "test(conductor): render-parity harness + fixtures vs legacy charts"
```

---

## Task 8: Final lint + parity gate

- [ ] **Step 1: Lint clean** — Run: `helm lint conductor` — Expected: `0 chart(s) failed`.

- [ ] **Step 2: Render clean for POC and HA**

Run: `helm template c conductor -f conductor/tests/values-unified.yaml >/dev/null && echo POC-OK`
Run: `helm template c conductor -f conductor/tests/values-unified.yaml --set ha.enabled=true >/dev/null && echo HA-OK`
Expected: both OK; the HA render includes a github-cache StatefulSet, the POC render does not.

- [ ] **Step 3: Confirm no selector cross-talk and no `conductor` in resource names**

Run: `helm template c conductor -f conductor/tests/values-unified.yaml | grep 'app.kubernetes.io/name:' | sort -u`
Expected: both `lakerunner` and `maestro` present and distinct (never a single shared name).

Run: `helm template c conductor -f conductor/tests/values-unified.yaml | grep -E '^  name:' | grep -i conductor || echo "no conductor-prefixed resource names — good"`
Expected: `no conductor-prefixed resource names — good`.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat(conductor): skeleton complete — lint clean, render parity vs legacy (A)"
```

---

## Self-review notes (spec coverage)

- Monolithic single chart → Tasks 1–6. ✓
- Single shared SA, splittable later → Task 3 (`conductor.serviceAccountName`, both families delegate). ✓
- Drop grafana/collector/perch → Task 4 (templates) + Task 6 (values). ✓
- Keep mcp-gateway/github-cache/dex → Task 5 (all maestro templates copied) + Task 8 HA check. ✓
- No `conductor` in resource names; release-name prefix only → Task 2 (name pins), Task 3 (release-named SA), Task 8 Step 3 guard. ✓
- Render parity exit criterion → Tasks 7–8. ✓
- No bootstrap/adoption/dex-consolidation here → deferred to B/C/D by design. ✓

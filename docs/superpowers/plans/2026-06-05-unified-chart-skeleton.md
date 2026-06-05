# Unified Chart Skeleton (Sub-project A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a single monolithic Helm chart `cardinal/` that renders the same in-scope resources as the legacy `lakerunner` + `maestro` charts combined, minus grafana/collector/perch, with one shared ServiceAccount by default.

**Architecture:** Vendor both charts' templates into one chart under `templates/lakerunner/`, `templates/maestro/`, and `templates/shared/`. Keep the two namespaced helper families (`lakerunner.*`, `maestro.*`) side by side — they don't collide as template names. Decouple each family's `name` from `.Chart.Name` (pin to `"lakerunner"`/`"maestro"`) so existing resource names and selector labels are preserved and pods don't cross-select. Merge `values.yaml` into one document. No bootstrap/adoption logic in this sub-project (that's B/C).

**Tech Stack:** Helm 3, Go templating. "Tests" = `helm lint` + `helm template` render-parity diffs against the legacy charts.

**Chart name decision (FLAGGED):** dir/name = `cardinal`. This changes only the `helm.sh/chart` label (not a selector label) vs the legacy charts. If the user prefers a different name (e.g. eventually reclaiming `lakerunner`), change `meta name`/dir in Task 1 only.

**Reference paths** (legacy charts live at repo root; the unified chart is new):
- Legacy: `lakerunner/`, `maestro/`
- New: `cardinal/`

---

## File Structure

```
cardinal/
  Chart.yaml
  values.yaml                       # merged from lakerunner + maestro values (dropped components removed)
  .helmignore
  templates/
    _helpers-lakerunner.tpl         # copy of lakerunner/templates/_helpers.tpl + name pin + SA repoint
    _helpers-maestro.tpl            # copy of maestro/templates/_helpers.tpl + name pin + SA repoint
    shared/
      serviceaccount.yaml           # ONE shared SA (replaces both legacy SAs)
      rbac.yaml                     # union Role + RoleBinding bound to the effective SA(s)
    lakerunner/                     # all in-scope lakerunner templates (grafana*/collector/perch* dropped)
    maestro/                        # all maestro templates (legacy serviceaccount.yaml dropped)
```

Subdirectories under `templates/` are flattened by Helm; they exist only to avoid filename collisions and aid readability.

---

## Task 1: Scaffold the `cardinal` chart

**Files:**
- Create: `cardinal/Chart.yaml`
- Create: `cardinal/.helmignore`

- [ ] **Step 1: Create the chart directory and Chart.yaml**

```bash
mkdir -p cardinal/templates/shared cardinal/templates/lakerunner cardinal/templates/maestro
```

Create `cardinal/Chart.yaml`:

```yaml
apiVersion: v2
name: cardinal
description: Unified Helm chart for CardinalHQ LakeRunner + Maestro
type: application
version: "0.1.0"
# appVersion is nominal only — component image tags are pinned per-component in values.yaml
# (both lakerunner.* and maestro.* image helpers would otherwise default the tag to this).
appVersion: "v1.52.0"
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

Copy the legacy one:

```bash
cp lakerunner/.helmignore cardinal/.helmignore
```

- [ ] **Step 3: Verify the chart is recognized (empty render)**

Run: `helm lint cardinal 2>&1 | head` — Expected: complains about no templates / empty values, but recognizes `cardinal` as a chart (no "Chart.yaml file is missing").

- [ ] **Step 4: Commit**

```bash
git add cardinal/Chart.yaml cardinal/.helmignore
git commit -m "feat(cardinal): scaffold unified chart skeleton"
```

---

## Task 2: Vendor and adapt the helper files

**Files:**
- Create: `cardinal/templates/_helpers-lakerunner.tpl` (from `lakerunner/templates/_helpers.tpl`)
- Create: `cardinal/templates/_helpers-maestro.tpl` (from `maestro/templates/_helpers.tpl`)

- [ ] **Step 1: Copy both helper files verbatim**

```bash
cp lakerunner/templates/_helpers.tpl cardinal/templates/_helpers-lakerunner.tpl
cp maestro/templates/_helpers.tpl    cardinal/templates/_helpers-maestro.tpl
```

- [ ] **Step 2: Pin `lakerunner.name` to a fixed base (preserve names + selector identity)**

In `cardinal/templates/_helpers-lakerunner.tpl`, replace the body of `lakerunner.name`:

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

Also update `lakerunner.fullname`'s `$name` default (same file): change `{{- $name := default .Chart.Name .Values.nameOverride }}` to `{{- $name := default "lakerunner" .Values.nameOverride }}`.

- [ ] **Step 3: Pin `maestro.name` to a fixed base**

In `cardinal/templates/_helpers-maestro.tpl`, replace the body of `maestro.name`:

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

Also update `maestro.fullname`'s `$name` default: change `{{- $name := default .Chart.Name .Values.nameOverride }}` to `{{- $name := default "maestro" .Values.nameOverride }}`.

> Note: `nameOverride`/`fullnameOverride` are now ambiguous across two families. The merged values.yaml (Task 6) sets neither; leaving them unset yields `<release>-lakerunner` / `<release>-maestro`. Per-component renaming, if ever needed, is a follow-up — not in scope for the skeleton.

- [ ] **Step 4: Verify the helper files parse**

Run: `helm template t cardinal --show-only templates/_helpers-lakerunner.tpl 2>&1 | head` — Expected: no parse error (renders nothing, since it's only defines). A "could not find template" message is fine; a YAML/parse error is not.

- [ ] **Step 5: Commit**

```bash
git add cardinal/templates/_helpers-lakerunner.tpl cardinal/templates/_helpers-maestro.tpl
git commit -m "feat(cardinal): vendor helper families, pin name bases to preserve identity"
```

---

## Task 3: Single shared ServiceAccount + RBAC

**Files:**
- Create: `cardinal/templates/shared/serviceaccount.yaml`
- Create: `cardinal/templates/shared/rbac.yaml`
- Modify: `cardinal/templates/_helpers-lakerunner.tpl` (repoint `lakerunner.serviceAccountName`)
- Modify: `cardinal/templates/_helpers-maestro.tpl` (repoint `maestro.serviceAccountName`)

- [ ] **Step 1: Add a shared SA-name helper to the lakerunner helper file**

Append to `cardinal/templates/_helpers-lakerunner.tpl`:

```
{{/*
Shared ServiceAccount name for the unified chart. Single SA by default;
override with .Values.serviceAccount.name. Per-component SAs (least-privilege)
are a future opt-in — for the skeleton, every workload uses this one SA.
*/}}
{{- define "cardinal.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (printf "%s-cardinal" .Release.Name | trunc 63 | trimSuffix "-") .Values.serviceAccount.name -}}
{{- else -}}
{{- .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}
```

- [ ] **Step 2: Repoint both family SA helpers at the shared one**

In `cardinal/templates/_helpers-lakerunner.tpl`, replace the `lakerunner.serviceAccountName` body to delegate:
```
{{- define "lakerunner.serviceAccountName" -}}
{{- include "cardinal.serviceAccountName" . -}}
{{- end }}
```

In `cardinal/templates/_helpers-maestro.tpl`, replace the `maestro.serviceAccountName` body to delegate:
```
{{- define "maestro.serviceAccountName" -}}
{{- include "cardinal.serviceAccountName" . -}}
{{- end }}
```

- [ ] **Step 3: Create the shared ServiceAccount template**

Create `cardinal/templates/shared/serviceaccount.yaml`:
```yaml
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "cardinal.serviceAccountName" . }}
  labels:
    {{- include "lakerunner.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
```

- [ ] **Step 4: Create the union Role + RoleBinding**

Inspect the legacy lakerunner Role (`lakerunner/templates/role.yaml`) and any maestro RBAC. Create `cardinal/templates/shared/rbac.yaml` as the union of their rules bound to `cardinal.serviceAccountName`. Use the legacy `lakerunner/templates/role.yaml` rules verbatim as the base (maestro had no Role of its own — confirm with `ls maestro/templates | grep -i role`; if none, the lakerunner rules are the complete union):

```yaml
{{- if .Values.serviceAccount.create -}}
{{- /* Base: copy the exact rules block from lakerunner/templates/role.yaml */ -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "cardinal.serviceAccountName" . }}
  labels:
    {{- include "lakerunner.labels" . | nindent 4 }}
rules:
  # <-- paste the rules: list from lakerunner/templates/role.yaml here, verbatim -->
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "cardinal.serviceAccountName" . }}
  labels:
    {{- include "lakerunner.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "cardinal.serviceAccountName" . }}
subjects:
  - kind: ServiceAccount
    name: {{ include "cardinal.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
{{- end }}
```

(Before writing, run `cat lakerunner/templates/role.yaml` and paste its actual `rules:` content into the placeholder comment — the plan author has not inlined it because the executing engineer must copy the current rules verbatim.)

- [ ] **Step 5: Commit**

```bash
git add cardinal/templates/_helpers-lakerunner.tpl cardinal/templates/_helpers-maestro.tpl cardinal/templates/shared/
git commit -m "feat(cardinal): single shared ServiceAccount + union RBAC"
```

---

## Task 4: Copy in-scope lakerunner templates (drop grafana/collector/perch)

**Files:**
- Create: `cardinal/templates/lakerunner/*.yaml` (in-scope subset)

- [ ] **Step 1: Copy every lakerunner template except dropped ones, helpers, and the replaced SA/role**

```bash
for f in lakerunner/templates/*.yaml; do
  base=$(basename "$f")
  case "$base" in
    grafana-*.yaml|collector.yaml|perch-*.yaml|serviceaccount.yaml|role.yaml) ;; # DROP / replaced
    *) cp "$f" "cardinal/templates/lakerunner/$base" ;;
  esac
done
ls cardinal/templates/lakerunner/
```

Expected `ls` output excludes: `grafana-datasources-configmap.yaml`, `grafana-deployment.yaml`, `grafana-service.yaml`, `collector.yaml`, `perch-clusterrole.yaml`, `perch-collectors-clusterrole.yaml`, `perch-collectors-role.yaml`, `perch-configmap.yaml`, `perch-deployment.yaml`, `serviceaccount.yaml`, `role.yaml`.

- [ ] **Step 2: Check for references to dropped components**

Run: `grep -rn "perch\|grafana\|collector" cardinal/templates/lakerunner/ | grep -v "#"` — Expected: no functional references (e.g. no `perch.enabled` gating left in copied files that breaks rendering). If a copied template references perch/grafana/collector values, note it; those values still exist in Task 6's values until explicitly removed. Resolve only hard render breaks here.

- [ ] **Step 3: Commit**

```bash
git add cardinal/templates/lakerunner/
git commit -m "feat(cardinal): add in-scope lakerunner templates (drop grafana/collector/perch)"
```

---

## Task 5: Copy maestro templates

**Files:**
- Create: `cardinal/templates/maestro/*.yaml` and `NOTES.txt`

- [ ] **Step 1: Copy every maestro template except helpers and the replaced SA**

```bash
for f in maestro/templates/*.yaml; do
  base=$(basename "$f")
  case "$base" in
    serviceaccount.yaml) ;; # replaced by shared SA
    *) cp "$f" "cardinal/templates/maestro/$base" ;;
  esac
done
cp maestro/templates/NOTES.txt cardinal/templates/NOTES.txt
ls cardinal/templates/maestro/
```

- [ ] **Step 2: Commit**

```bash
git add cardinal/templates/maestro/ cardinal/templates/NOTES.txt
git commit -m "feat(cardinal): add maestro templates (drop legacy SA)"
```

---

## Task 6: Build the merged values.yaml

**Files:**
- Create: `cardinal/values.yaml`

- [ ] **Step 1: Concatenate the two values files as a starting point**

```bash
{ echo '# Unified cardinal chart values (merged from lakerunner + maestro)'; \
  echo '# === lakerunner ==='; cat lakerunner/values.yaml; \
  echo; echo '# === maestro ==='; cat maestro/values.yaml; } > cardinal/values.yaml
```

- [ ] **Step 2: Resolve the two `global:` blocks and `serviceAccount:` blocks into one each**

Both charts define top-level `global:` and `serviceAccount:`. YAML last-key-wins would silently drop the first. Manually merge so there is exactly ONE `global:` (union of lakerunner + maestro global keys) and ONE `serviceAccount:` block:

```yaml
serviceAccount:
  create: true
  name: ""        # empty → cardinal.serviceAccountName derives "<release>-cardinal"
  annotations: {}
```

Remove the now-duplicate second `global:`/`serviceAccount:`/`nameOverride`/`fullnameOverride` keys. Verify only one of each remains:

Run: `grep -nE '^(global|serviceAccount|nameOverride|fullnameOverride):' cardinal/values.yaml` — Expected: exactly one line per key.

- [ ] **Step 3: Remove values for dropped components**

Delete the `grafana:`, `collector:`, and `perch:` top-level blocks from `cardinal/values.yaml`.

Run: `grep -nE '^(grafana|collector|perch):' cardinal/values.yaml` — Expected: no output.

- [ ] **Step 4: Pin per-component image tags (do not rely on appVersion)**

Set explicit tags so each component image matches its legacy default. Read the legacy effective tags first:

```bash
helm template lr lakerunner | grep -m1 'image:.*lakerunner'
helm template ms maestro     | grep -m1 'image:.*maestro'
```

In `cardinal/values.yaml`, set the lakerunner image tag (e.g. under `global.image.tag` or `setup.image.tag` etc. as the legacy chart expects) and `image.tag` (maestro's top-level image block) to the versions observed above, instead of leaving them empty (empty → defaults to the single `Chart.appVersion`, which is wrong for one of the two).

- [ ] **Step 5: Lint**

Run: `helm lint cardinal` — Expected: `1 chart(s) linted, 0 chart(s) failed`. Fix any template errors surfaced (most likely a stray reference to a removed value).

- [ ] **Step 6: Commit**

```bash
git add cardinal/values.yaml
git commit -m "feat(cardinal): merged values (one global/SA, drop grafana/collector/perch, pin image tags)"
```

---

## Task 7: Render-parity verification against the legacy charts

**Files:**
- Create: `cardinal/tests/render-parity.sh`

- [ ] **Step 1: Write the parity script**

Create `cardinal/tests/render-parity.sh`:

```bash
#!/usr/bin/env bash
# Renders legacy lakerunner+maestro and the unified cardinal chart with equivalent
# values, normalizes incidental differences (helm.sh/chart label, release name),
# and diffs the resulting resource sets. Exit 0 == parity (modulo dropped components).
set -euo pipefail
REL="cardinal-test"
OUT=$(mktemp -d)

# Provide equivalent minimal values for all three renders via these files
LR_VALUES="${1:?path to lakerunner test values}"
MS_VALUES="${2:?path to maestro test values}"
UNIFIED_VALUES="${3:?path to unified test values}"

norm() { sed -E 's/helm\.sh\/chart: [^ ]+//; s/'"$REL"'-(lakerunner|maestro|cardinal)/REL/g'; }

helm template "$REL" lakerunner -f "$LR_VALUES" | norm | yq -P 'sort_keys(..)' > "$OUT/legacy.yaml" 2>/dev/null || \
  helm template "$REL" lakerunner -f "$LR_VALUES" | norm > "$OUT/legacy-lr.yaml"
helm template "$REL" maestro    -f "$MS_VALUES" | norm > "$OUT/legacy-ms.yaml"
helm template "$REL" cardinal   -f "$UNIFIED_VALUES" | norm > "$OUT/unified.yaml"

echo "Rendered into $OUT — compare resource kinds/names:"
grep -E '^(kind|  name):' "$OUT/legacy-lr.yaml" "$OUT/legacy-ms.yaml" | sort > "$OUT/legacy-index.txt"
grep -E '^(kind|  name):' "$OUT/unified.yaml" | sort > "$OUT/unified-index.txt"
diff "$OUT/legacy-index.txt" "$OUT/unified-index.txt" || true
echo "Dropped-on-purpose (expected only on legacy side): grafana, collector, perch"
```

```bash
chmod +x cardinal/tests/render-parity.sh
```

- [ ] **Step 2: Create minimal test values**

Create `cardinal/tests/values-lakerunner.yaml`, `cardinal/tests/values-maestro.yaml`, and `cardinal/tests/values-unified.yaml` with the minimum required fields for each chart to render (DB host, object store bucket, license, base URL for maestro, etc.). Use the legacy charts' `tests/` fixtures as a reference for required fields:

```bash
ls lakerunner/tests/ maestro/tests/
```

Copy the smallest passing fixture from each legacy `tests/` dir as the basis, and build `values-unified.yaml` by merging the two (mirroring the values.yaml merge).

- [ ] **Step 3: Run parity**

Run: `cardinal/tests/render-parity.sh cardinal/tests/values-lakerunner.yaml cardinal/tests/values-maestro.yaml cardinal/tests/values-unified.yaml`

Expected: the diff shows the unified side contains every `kind`/`name` from both legacy renders EXCEPT the dropped grafana/collector/perch resources and the two legacy ServiceAccounts (replaced by one `*-cardinal` SA). No unexpected missing or duplicate resources.

- [ ] **Step 4: Resolve duplicate-resource-name conflicts**

If `helm template cardinal` errors with a duplicate resource name (most likely the shared `license` Secret or `cardinal-api-key` Secret rendered by both families), dedupe: keep one definition and point the other family's `*SecretName` helper / reference at it. Re-run Step 3 until clean.

Run: `helm template cardinal-test cardinal -f cardinal/tests/values-unified.yaml >/dev/null && echo OK` — Expected: `OK` (renders with no duplicate-name error).

- [ ] **Step 5: Commit**

```bash
git add cardinal/tests/
git commit -m "test(cardinal): render-parity harness vs legacy charts"
```

---

## Task 8: Final lint + parity gate

- [ ] **Step 1: Lint clean**

Run: `helm lint cardinal` — Expected: `0 chart(s) failed`.

- [ ] **Step 2: Render clean for both a POC and an HA values set**

Run: `helm template c cardinal -f cardinal/tests/values-unified.yaml --set ha.enabled=true >/dev/null && echo HA-OK`
Run: `helm template c cardinal -f cardinal/tests/values-unified.yaml >/dev/null && echo POC-OK`
Expected: `HA-OK` (github-cache StatefulSet appears) and `POC-OK` (github-cache absent).

- [ ] **Step 3: Confirm no selector cross-talk**

Run: `helm template c cardinal -f cardinal/tests/values-unified.yaml | grep -A2 'app.kubernetes.io/name:' | sort -u`
Expected: both `app.kubernetes.io/name: lakerunner` and `app.kubernetes.io/name: maestro` present and distinct — never a single shared name across both products.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat(cardinal): skeleton complete — lint clean, render parity vs legacy (A)"
```

---

## Self-review notes (spec coverage)

- Monolithic single chart → Tasks 1–6. ✓
- Single shared SA, splittable later → Task 3 (`cardinal.serviceAccountName`, both families delegate). ✓
- Drop grafana/collector/perch → Task 4 (templates) + Task 6 (values). ✓
- Keep mcp-gateway/github-cache/dex → Task 5 (all maestro templates copied) + Task 8 HA check. ✓
- Render parity exit criterion → Tasks 7–8. ✓
- No bootstrap/adoption/dex-consolidation here → deferred to B/C/D by design. ✓
- Flagged for user: chart name `cardinal` (Task 1); per-component image-tag pinning (Task 6 Step 4).

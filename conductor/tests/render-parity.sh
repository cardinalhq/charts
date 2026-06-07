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
# Build sorted, filename-free (kind|name) indexes so the diff is readable.
idx() { grep -hE '^(kind|  name):' "$@" | sed -E 's/^  name: +/  name: /' | sort -u; }
idx "$OUT/legacy-lr.yaml" "$OUT/legacy-ms.yaml" > "$OUT/legacy-index.txt"
idx "$OUT/unified.yaml" > "$OUT/unified-index.txt"
echo "### LEGACY-ONLY (present in legacy, removed in unified):"
comm -23 "$OUT/legacy-index.txt" "$OUT/unified-index.txt"
echo "### UNIFIED-ONLY (added in unified):"
comm -13 "$OUT/legacy-index.txt" "$OUT/unified-index.txt"
echo "### Expected LEGACY-ONLY: grafana/collector/perch resources + the 2 legacy ServiceAccounts"
echo "###   (release-named SA 'lakerunner', '<rel>-maestro') + the legacy lakerunner '<rel>-lakerunner-scaler' Role/RoleBinding."
echo "### Expected UNIFIED-ONLY: one release-named ServiceAccount/Role/RoleBinding ('<rel>')."
echo "OUT=$OUT"

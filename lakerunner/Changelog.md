# Changelog

## 3.16.22

* **REMOVED**: the Perch operator. Deleted the `perch` deployment, configmap,
  ClusterRole, and collectors Role/ClusterRole templates along with the
  `perch.*` values block. The OpenShift "Perch needs elevated RBAC" note is
  gone too.

## 3.16.3

* **CHANGED**: trimmed the `-scaler` Role down to what the workloads actually
  use. Removed the `deployments`/`deployments/scale` patch/update grant (dead
  since the in-product PI autoscaler was removed in 3.16.0 — HPA scaling is done
  by the kube-controller-manager, not the workload ServiceAccount), plus the
  unused `pods` read and `coordination.k8s.io` `leases` grant. Service discovery
  (`services`, `endpointslices`) is retained. perch's Deployment access is
  unaffected — it comes from `perch-clusterrole`, not this Role.
* **NEW**: the Role now grants read (`get`/`list`/`watch`) on
  `autoscaling` `horizontalpodautoscalers` in the release namespace.

## 3.16.2

* **CHANGED**: HPA default CPU target
  `global.autoscaling.hpa.targetCPUUtilizationPercentage` 90 → 80. The 90%
  target left no burst headroom and, combined with the controller's default
  10% tolerance, pushed the effective scale-up trigger to ~99% — pods ran
  pinned near saturation before a second replica was added. 80% gives the
  process-* workers room to scale before they saturate.

## 3.16.0

* **CHANGED**: the process-* workers are now always scaled by a
  `HorizontalPodAutoscaler`. The in-product PI autoscaler has been removed from
  LakeRunner, so the chart no longer wires it up.
* **REMOVED**: `global.autoscaling.mode` (the `"hpa"` / `"worklane"` selector)
  and `monitoring.autoscaler` (`observeOnly`). The chart no longer emits the
  `LAKERUNNER_AUTOSCALER_*` env vars on the monitoring container. Per-service
  `autoscaling.minReplicas/maxReplicas` and `global.autoscaling.hpa` are
  unchanged; set a service's min/max both to 0 to disable its HPA.
* **CHANGED**: HPA defaults tuned for more aggressive scale-up — CPU target
  `global.autoscaling.hpa.targetCPUUtilizationPercentage` 85 → 90, and the
  scale-up `behavior` now adds up to 8 pods (was 4) per 30s window (was 60s).

## 3.15.0

* **NEW**: `global.autoscaling.mode` selects how the process-* workers are scaled.
  - `"hpa"` (default): the chart renders one `HorizontalPodAutoscaler` per
    enabled process-* worker (CPU-target, bounds from each service's
    `autoscaling.minReplicas/maxReplicas`), and the built-in PI autoscaler runs
    in report-only mode — it still emits the worklane depth/age metrics but does
    not scale. Wired via `LAKERUNNER_AUTOSCALER_REPORT_ONLY=true` on the
    monitoring container.
  - `"worklane"`: the built-in delay-aware PI autoscaler owns replica decisions
    (the previous behavior) and no HPA is rendered.
    `monitoring.autoscaler.observeOnly` still applies.
  - **CHANGED**: the default is now `"hpa"`, so out of the box replica decisions
    move from the built-in PI autoscaler to a Kubernetes HPA. Set
    `global.autoscaling.mode: worklane` to restore the previous behavior.
* **NEW**: `global.autoscaling.hpa` configures the rendered HPAs —
  `targetCPUUtilizationPercentage` (default 85) and a `behavior` block (fast
  scale-up, 120s scale-down stabilization to damp flapping). Both can be
  overridden per-service under `processLogs/processMetrics/processTraces.autoscaling`.
  The process-* Deployments omit `spec.replicas`, so the HPA owns the count
  without fighting the rendered manifest.

## 3.9.0

* **CHANGED**: Rebalanced worker pod memory math (process-logs, process-metrics, process-traces)
  - Replaced `LAKERUNNER_DUCKDB_MEMORY_LIMIT = container - 1Gi` (constant carve-out) with
    `LAKERUNNER_DUCKDB_MEMORY_LIMIT = 40% of container` (percentage-based, floor 512 MB)
  - Replaced `GOMEMLIMIT = 750MiB` (constant) with `GOMEMLIMIT = 20% of container`,
    clamped to `[256, 1024]` MiB
  - Reserves ~40% of the container for cgo allocator overhead, DuckDB peak overshoot,
    and transient allocations not tracked by DuckDB's `memory_limit`. Empirically
    real RSS overshoots `memory_limit` ~2× under heavy hash builds / sorts.
  - Operators with explicit overrides for `LAKERUNNER_DUCKDB_MEMORY_LIMIT` or `GOMEMLIMIT`
    are unaffected (existing `hasEnvVar` guard).
* **NEW**: `MALLOC_ARENA_MAX=2` injected by `duckdbRuntimeEnv` and `queryWorkerRuntimeEnv`
  - Collapses glibc per-thread arena fragmentation for cgo-heavy DuckDB workloads
  - Measured impact: process-metrics RSS dropped from 3.3 GiB → 1.25 GiB on a primed
    pod with no other change; eliminated 64-MiB sub-heap fragmentation pattern in
    `/proc/<pid>/smaps`
  - Operators may override per-component or in `global.env`

## 3.8.0

* **NEW**: Optional `perch.maestro.apiKey.existingSecret` value for self-hosted
  topologies that need a separate API key for the local maestro
  - Required when `perch.maestro.url` is NOT `https://app.cardinalhq.io`
  - Wires `MAESTRO_API_KEY` env var into the perch container via `secretKeyRef`
  - Works in conjunction with the lakerunner change that sends version reports
    to CardinalHQ and collector inventory to the local maestro
  - When unset, perch falls back to the license-derived key (preserves
    behavior for SaaS-only deployments)
  - Requires lakerunner image with the matching split-traffic change

## 0.4.0

* **NEW**: Simplified Grafana Cardinal datasource configuration
  - New `grafana.cardinal.*` configuration section for easier setup
  - Only requires `grafana.cardinal.apiKey` for basic configuration
  - Auto-configures endpoint to deployed query-api service
  - Optional customization: endpoint, name, isDefault, editable
  - Backward compatible: existing `grafana.datasources` configuration still works
  - Creates separate `lakerunner.yaml` file to avoid conflicts with additional datasources

* **VALIDATION**: Add database configuration validation for multiple Grafana replicas
  - Prevents deployment of multiple Grafana replicas without external database configuration
  - Fails fast with clear error message instead of runtime pod failures
  - Validates for `GF_DATABASE_TYPE` environment variable in both `grafana.env` and `global.env`
  - Single replica deployments continue to work without external database (uses SQLite)

## 0.3.0

* **MAJOR**: Add KEDA autoscaling support with intelligent work queue-based scaling
  - Global scaling mode configuration: `hpa`, `keda`, or `disabled`
  - Per-component scaling mode overrides
  - PostgreSQL query-based scaling for micro-batch workloads
  - KEDA ScaledObjects for all scalable components (ingest-logs, ingest-metrics, compact-logs, compact-metrics, rollup-metrics)
  - Automatic HPA vs KEDA conflict prevention
  - Comprehensive KEDA testing and documentation
  - Production recommendation: Use KEDA for production environments as CPU-based HPA is insufficient for micro-batch workloads

* **SECURITY**: Update LakeRunner components to use distroless-compatible security context
  - Change runAsUser/runAsGroup/fsGroup from 2000 to 65532 for all LakeRunner components
  - Aligns with distroless base image non-root user (65532)
  - Grafana component unchanged (continues using userid 472)
  - Maintains all existing security hardening (non-root, dropped capabilities, seccomp)

## 0.2.36

* Add a configurable pod termination grace period, default to 600 seconds
  for ingest, and 300 seconds for other processing workers.  Non-processing
  pods are 120 seconds.

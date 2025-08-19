# Changelog

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

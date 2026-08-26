{{/*
Expand the name of the chart.
*/}}
{{- define "lakerunner.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Render imagePullSecrets.
*/}}
{{- define "lakerunner.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "lakerunner.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "lakerunner.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels, now including .Values.global.labels.
*/}}
{{- define "lakerunner.labels" -}}
  {{- $global := .Values.global.labels | default dict -}}
  {{- $labels := merge
      (dict "helm.sh/chart" (include "lakerunner.chart" .))
      (include "lakerunner.selectorLabels" . | fromYaml)
  -}}
  {{- if .Chart.AppVersion -}}
    {{- $labels = merge $labels (dict "app.kubernetes.io/version" (.Chart.AppVersion)) -}}
  {{- end -}}
  {{- $labels = merge $labels (dict "app.kubernetes.io/managed-by" .Release.Service) -}}
  {{- $labels = merge $labels (dict "lakerunner.cardinalhq.io/instance" .Release.Name) -}}
  {{- $labels = merge $labels $global -}}
  {{- toYaml $labels -}}
{{- end }}

{{/*
Common labels with component-specific labels support.
Usage: {{ include "lakerunner.labelsWithComponent" (list . .Values.componentName.labels) }}
*/}}
{{- define "lakerunner.labelsWithComponent" -}}
  {{- $context := index . 0 -}}
  {{- $componentLabels := index . 1 | default dict -}}
  {{- $global := $context.Values.global.labels | default dict -}}
  {{- $coreLabels := merge
      (dict "helm.sh/chart" (include "lakerunner.chart" $context))
      (include "lakerunner.selectorLabels" $context | fromYaml)
  -}}
  {{- if $context.Chart.AppVersion -}}
    {{- $coreLabels = merge $coreLabels (dict "app.kubernetes.io/version" ($context.Chart.AppVersion)) -}}
  {{- end -}}
  {{- $coreLabels = merge $coreLabels (dict "app.kubernetes.io/managed-by" $context.Release.Service) -}}
  {{- $coreLabels = merge $coreLabels (dict "lakerunner.cardinalhq.io/instance" $context.Release.Name) -}}
  {{- $withGlobal := merge $global $coreLabels -}}
  {{- $finalLabels := merge $componentLabels $withGlobal -}}
  {{- toYaml $finalLabels -}}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "lakerunner.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lakerunner.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "lakerunner.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "lakerunner.fullname" .) .Values.serviceAccount.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Dedicated service accounts for the default-off generation shadow lane. */}}
{{- define "lakerunner.generationCoordinatorServiceAccountName" -}}
{{- default (printf "%s-generation-coordinator" (include "lakerunner.fullname" .)) .Values.generation.coordinator.serviceAccount.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "lakerunner.generationShardBuilderServiceAccountName" -}}
{{- default (printf "%s-generation-shard-builder" (include "lakerunner.fullname" .)) .Values.generation.shardBuilder.serviceAccount.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Generation workloads are intentionally pinned by digest and do not inherit the
tag-oriented global image settings used by established workloads.
*/}}
{{- define "lakerunner.generationImage" -}}
{{- printf "%s@%s" .Values.generation.image.repository .Values.generation.image.digest -}}
{{- end -}}

{{/*
Reject user env entries that would duplicate or override environment owned by
the generation Deployments and their shared helpers.
Args:
  0: env list
  1: values path used in the error
*/}}
{{- define "lakerunner.validateGenerationEnv" -}}
{{- $envList := index . 0 | default list -}}
{{- $path := index . 1 -}}
{{- $reserved := list
  "OTEL_SERVICE_NAME"
  "LAKERUNNER_GENERATION_COORDINATOR_ENABLED"
  "LAKERUNNER_GENERATION_COORDINATOR_LEASE_DURATION"
  "LAKERUNNER_GENERATION_COORDINATOR_TERMINATION_GRACE"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_ENABLED"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_LEASE_DURATION"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_POLL_INTERVAL"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_NO_WORK_BACKOFF_INITIAL"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_NO_WORK_BACKOFF_MAX"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_ERROR_BACKOFF_INITIAL"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_ERROR_BACKOFF_MAX"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_BACKOFF_JITTER"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_CONCURRENCY"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_SCRATCH_DIRECTORY"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_SCRATCH_LIMIT_BYTES"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_RESIDENT_MEMORY_LIMIT_BYTES"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_SPILL_FAIL_THRESHOLD_BYTES"
  "LAKERUNNER_GENERATION_SHARD_BUILDER_TERMINATION_GRACE"
  "LAKERUNNER_LKRN_GEN_SHARD"
  "AZURE_AUTH_TYPE"
  "LRDB_HOST"
  "LRDB_PORT"
  "LRDB_DBNAME"
  "LRDB_USER"
  "LRDB_PASSWORD"
  "LRDB_SSLMODE"
  "CONFIGDB_HOST"
  "CONFIGDB_PORT"
  "CONFIGDB_DBNAME"
  "CONFIGDB_USER"
  "CONFIGDB_PASSWORD"
  "CONFIGDB_SSLMODE"
  "STORAGE_PROFILE_FILE"
  "GOMEMLIMIT"
  "GOGC"
  "OTEL_TRACES_SAMPLER"
  "OTEL_TRACES_SAMPLER_ARG"
  "cardinalhq-api-key"
  "OTEL_EXPORTER_OTLP_ENDPOINT"
  "ENABLE_OTLP_TELEMETRY"
  "OTEL_EXPORTER_OTLP_HEADERS"
-}}
{{- range $entry := $envList -}}
  {{- $name := $entry.name | default "" | toString -}}
  {{- if has $name $reserved -}}
    {{- fail (printf "%s must not set reserved generation environment variable %s" $path $name) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/* Fail rendering rather than admitting an unsafe generation shadow pod. */}}
{{- define "lakerunner.validateGenerationShadow" -}}
{{- $coordinator := .Values.generation.coordinator -}}
{{- $builder := .Values.generation.shardBuilder -}}
{{- if or $coordinator.enabled $builder.enabled -}}
  {{- if not .Values.generation.image.repository -}}
    {{- fail "generation.image.repository is required when a generation workload is enabled" -}}
  {{- end -}}
  {{- if or (contains "@" (.Values.generation.image.repository | toString)) (regexMatch ":[^/]+$" (.Values.generation.image.repository | toString)) -}}
    {{- fail "generation.image.repository must not contain a tag or digest; set the lowercase sha256 digest only in generation.image.digest" -}}
  {{- end -}}
  {{- if not (regexMatch "^sha256:[0-9a-f]{64}$" (.Values.generation.image.digest | toString)) -}}
    {{- fail "generation.image.digest must be sha256: followed by exactly 64 lowercase hexadecimal characters" -}}
  {{- end -}}
  {{- include "lakerunner.validateGenerationEnv" (list (.Values.global.env | default list) "global.env") -}}
  {{- $coordinatorSA := include "lakerunner.generationCoordinatorServiceAccountName" . -}}
  {{- $builderSA := include "lakerunner.generationShardBuilderServiceAccountName" . -}}
  {{- $generalSA := include "lakerunner.serviceAccountName" . -}}
  {{- if and $coordinator.enabled (eq $coordinatorSA $generalSA) -}}
    {{- fail "generation coordinator service account must be distinct from the general lakerunner service account" -}}
  {{- end -}}
  {{- if and $builder.enabled (eq $builderSA $generalSA) -}}
    {{- fail "generation shard builder service account must be distinct from the general lakerunner service account" -}}
  {{- end -}}
  {{- if and $coordinator.enabled $builder.enabled (eq $coordinatorSA $builderSA) -}}
    {{- fail "generation coordinator and shard builder service accounts must be distinct" -}}
  {{- end -}}
{{- end -}}
{{- if $coordinator.enabled -}}
  {{- include "lakerunner.validateGenerationEnv" (list ($coordinator.env | default list) "generation.coordinator.env") -}}
  {{- if or (ne (int $coordinator.terminationGraceSeconds) 30) (ne (int $coordinator.podTerminationGraceSeconds) 45) (ne (int $coordinator.leaseDurationSeconds) 300) -}}
    {{- fail "generation coordinator timing must remain terminationGraceSeconds=30, podTerminationGraceSeconds=45, leaseDurationSeconds=300 during shadow rollout" -}}
  {{- end -}}
  {{- if not (and (lt (int $coordinator.terminationGraceSeconds) (int $coordinator.podTerminationGraceSeconds)) (lt (int $coordinator.podTerminationGraceSeconds) (int $coordinator.leaseDurationSeconds))) -}}
    {{- fail "generation coordinator grace periods must satisfy terminationGraceSeconds < podTerminationGraceSeconds < leaseDurationSeconds" -}}
  {{- end -}}
{{- end -}}
{{- if $builder.enabled -}}
  {{- include "lakerunner.validateGenerationEnv" (list ($builder.env | default list) "generation.shardBuilder.env") -}}
  {{- if or (ne (int $builder.terminationGraceSeconds) 30) (ne (int $builder.podTerminationGraceSeconds) 45) (ne (int $builder.leaseDurationSeconds) 300) -}}
    {{- fail "generation shard builder timing must remain terminationGraceSeconds=30, podTerminationGraceSeconds=45, leaseDurationSeconds=300 during shadow rollout" -}}
  {{- end -}}
  {{- if ne (int $builder.concurrency) 1 -}}
    {{- fail "generation.shardBuilder.concurrency must be exactly 1 during shadow rollout" -}}
  {{- end -}}
  {{- if ne (int64 $builder.scratchLimitBytes) 17179869184 -}}
    {{- fail "generation.shardBuilder.scratchLimitBytes must be exactly 17179869184 (16Gi) during shadow rollout" -}}
  {{- end -}}
  {{- if ne ($builder.scratchDirectory | toString) "/scratch/generation" -}}
    {{- fail "generation.shardBuilder.scratchDirectory must be /scratch/generation" -}}
  {{- end -}}
  {{- $scratchSize := include "lakerunner.parseMemoryToBytes" $builder.scratchSizeLimit | int64 -}}
  {{- if lt $scratchSize 18253611008 -}}
    {{- fail "generation.shardBuilder.scratchSizeLimit must be at least 17Gi" -}}
  {{- end -}}
  {{- $memoryRequest := include "lakerunner.parseMemoryToBytes" $builder.resources.requests.memory | int64 -}}
  {{- $memoryLimit := include "lakerunner.parseMemoryToBytes" $builder.resources.limits.memory | int64 -}}
  {{- if or (le $memoryRequest 0) (le $memoryLimit 0) (gt $memoryRequest $memoryLimit) (gt $memoryLimit 2147483648) -}}
    {{- fail "generation shard builder memory must be positive, request <= limit, and limit <= 2Gi" -}}
  {{- end -}}
  {{- if or (le (int64 $builder.residentMemoryLimitBytes) 0) (gt (int64 $builder.residentMemoryLimitBytes) $memoryLimit) -}}
    {{- fail "generation.shardBuilder.residentMemoryLimitBytes must be positive and no greater than the container memory limit" -}}
  {{- end -}}
  {{- if or (le (int64 $builder.spillFailThresholdBytes) 0) (ge (int64 $builder.spillFailThresholdBytes) (int64 $builder.residentMemoryLimitBytes)) -}}
    {{- fail "generation.shardBuilder.spillFailThresholdBytes must be positive and below residentMemoryLimitBytes" -}}
  {{- end -}}
  {{- $ephemeralRequest := include "lakerunner.parseMemoryToBytes" (index $builder.resources.requests "ephemeral-storage") | int64 -}}
  {{- $ephemeralLimit := include "lakerunner.parseMemoryToBytes" (index $builder.resources.limits "ephemeral-storage") | int64 -}}
  {{- if or (lt $ephemeralRequest 19327352832) (lt $ephemeralLimit 19327352832) (gt $ephemeralRequest $ephemeralLimit) -}}
    {{- fail "generation shard builder ephemeral-storage request and limit must be at least 18Gi and request <= limit" -}}
  {{- end -}}
  {{- if not (and (lt (int $builder.terminationGraceSeconds) (int $builder.podTerminationGraceSeconds)) (lt (int $builder.podTerminationGraceSeconds) (int $builder.leaseDurationSeconds))) -}}
    {{- fail "generation shard builder grace periods must satisfy terminationGraceSeconds < podTerminationGraceSeconds < leaseDurationSeconds" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Builder-specific environment composition. The builder hosts a Go supervisor
and a separately budgeted Rust child in one 2Gi pod, so generic Go memory
auto-tuning and operator overrides are unsafe here.
*/}}
{{- define "lakerunner.injectGenerationShardBuilderEnv" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- $globalEnv := $root.Values.global.env | default list -}}
{{- $compEnv := $comp.env | default list -}}
{{- include "lakerunner.commonEnv" $root | nindent 2 }}
  - name: GOMEMLIMIT
    value: "512MiB"
  - name: GOGC
    value: "50"
{{ include "lakerunner.tracesEnv" (list $root $comp) | nindent 2 -}}
{{- with $globalEnv }}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- with $compEnv }}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- end -}}

{{/*
Common environment variables
*/}}
{{- define "lakerunner.commonEnv" -}}
{{- include "lakerunner.dbEnv" (list . .Values.database .Values.configdb) -}}
{{- end }}

{{/*
Database environment variables with optional per-component overrides.
Args:
  0: root context
  1: database config (may have overrides)
  2: configdb config (may have overrides)
*/}}
{{- define "lakerunner.dbEnv" -}}
{{- $root := index . 0 -}}
{{- $db := index . 1 -}}
{{- $cdb := index . 2 -}}
- name: LRDB_HOST
  value: {{ $db.lrdb.host | quote }}
- name: LRDB_PORT
  value: {{ $db.lrdb.port | quote }}
- name: LRDB_DBNAME
  value: {{ $db.lrdb.name | quote }}
- name: LRDB_USER
  value: {{ $db.lrdb.username | quote }}
- name: LRDB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "lakerunner.databaseSecretName" $root }}
      key: {{ $root.Values.database.passwordKey }}
- name: LRDB_SSLMODE
  value: {{ $db.lrdb.sslMode | quote }}
- name: CONFIGDB_HOST
  value: {{ $cdb.lrdb.host | quote }}
- name: CONFIGDB_PORT
  value: {{ $cdb.lrdb.port | quote }}
- name: CONFIGDB_DBNAME
  value: {{ $cdb.lrdb.name | quote }}
- name: CONFIGDB_USER
  value: {{ $cdb.lrdb.username | quote }}
- name: CONFIGDB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "lakerunner.configdbSecretName" $root }}
      key: {{ $root.Values.configdb.passwordKey }}
- name: CONFIGDB_SSLMODE
  value: {{ $cdb.lrdb.sslMode | quote }}
{{- if eq $root.Values.storageProfiles.source "config" }}
- name: STORAGE_PROFILE_FILE
  value: "/app/config/storage_profiles.yaml"
{{- end -}}
{{- end }}

{{/*
Setup job environment variables.
Merges setup-specific database/configdb overrides with global defaults.
Empty override values fall back to the global config.
*/}}
{{- define "lakerunner.setupEnv" -}}
{{- $sdb := .Values.setup.database.lrdb -}}
{{- $gdb := .Values.database.lrdb -}}
{{- $scdb := .Values.setup.configdb.lrdb -}}
{{- $gcdb := .Values.configdb.lrdb -}}
{{- $mergedDb := dict "lrdb" (dict
  "host" (default $gdb.host $sdb.host)
  "port" (default $gdb.port $sdb.port)
  "name" (default $gdb.name $sdb.name)
  "username" (default $gdb.username $sdb.username)
  "sslMode" (default $gdb.sslMode $sdb.sslMode)
) -}}
{{- $mergedCdb := dict "lrdb" (dict
  "host" (default $gcdb.host $scdb.host)
  "port" (default $gcdb.port $scdb.port)
  "name" (default $gcdb.name $scdb.name)
  "username" (default $gcdb.username $scdb.username)
  "sslMode" (default $gcdb.sslMode $scdb.sslMode)
) -}}
{{- include "lakerunner.dbEnv" (list . $mergedDb $mergedCdb) -}}
{{- end }}

{{/*
Generate OpenTelemetry trace sampling env vars.
Reads global.monitoring.traces, then merges in per-component <comp>.monitoring.traces
(component values win for any keys they define).
Takes one or two args:
  0: the root chart context
  1: (optional) the component's values block (may set .monitoring.traces.{sampler,arg})
Usage:
  {{ include "lakerunner.tracesEnv" (list . .Values.queryApi) }}
  {{ include "lakerunner.tracesEnv" (list .) }}
*/}}
{{- define "lakerunner.tracesEnv" -}}
{{- $root := index . 0 -}}
{{- $comp := dict -}}
{{- if gt (len .) 1 -}}
{{- $compArg := index . 1 -}}
{{- if $compArg -}}{{- $comp = $compArg -}}{{- end -}}
{{- end -}}
{{- $traces := dict -}}
{{- if and $root.Values.global.monitoring $root.Values.global.monitoring.traces -}}
{{- $traces = deepCopy $root.Values.global.monitoring.traces -}}
{{- end -}}
{{- if and $comp.monitoring $comp.monitoring.traces -}}
{{- $traces = merge (deepCopy $comp.monitoring.traces) $traces -}}
{{- end -}}
{{- if $traces.sampler }}
- name: OTEL_TRACES_SAMPLER
  value: {{ $traces.sampler | quote }}
{{- end }}
{{- if hasKey $traces "arg" }}
- name: OTEL_TRACES_SAMPLER_ARG
  value: {{ $traces.arg | quote }}
{{- end }}
{{- end -}}

{{/*
Inject setup env vars (with database overrides) + component-specific env vars.
Takes two args:
  0: the root chart context
  1: the component's values block (must have .env as a list)
Usage:
  {{ include "lakerunner.injectEnvSetup" (list . .Values.setup) | nindent 10 }}
*/}}
{{- define "lakerunner.injectEnvSetup" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- include "lakerunner.setupEnv" $root | nindent 2 -}}
{{- include "lakerunner.goRuntimeEnv" (list $root $comp $comp.env) | nindent 2 -}}
{{- include "lakerunner.tracesEnv" (list $root $comp) | nindent 2 -}}
{{- with $root.Values.global.env -}}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- with $comp.env -}}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- end -}}

{{/*
Inject common + component-specific env vars.
Takes two args:
  0: the root chart context (so we can call commonEnv with it)
  1: the component's values block (must have .env as a list)
Usage:
  {{ include "lakerunner.injectEnv" (list . .Values.queryWorker) | nindent 10 }}
*/}}
{{- define "lakerunner.injectEnv" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- include "lakerunner.commonEnv" $root | nindent 2 -}}
{{- include "lakerunner.goRuntimeEnv" (list $root $comp $comp.env) | nindent 2 -}}
{{- include "lakerunner.tracesEnv" (list $root $comp) | nindent 2 -}}
{{- with $root.Values.global.env -}}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- with $comp.env -}}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- end -}}

{{/*
Inject common + component-specific env vars for the process-* workers
(process-logs/metrics/traces). These no longer use DuckDB in-process and need
LKRN/Go memory tuning instead.
Takes two args:
  0: the root chart context (so we can call commonEnv with it)
  1: the component's values block (must have .env as a list)
Usage:
  {{ include "lakerunner.injectEnvLkrn" (list . .Values.processLogs) | nindent 10 }}
*/}}
{{- define "lakerunner.injectEnvLkrn" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- include "lakerunner.commonEnv" $root | nindent 2 -}}
{{- include "lakerunner.lkrnRuntimeEnv" (list $root $comp $comp.env) | nindent 2 -}}
{{- include "lakerunner.tracesEnv" (list $root $comp) | nindent 2 -}}
{{- with $root.Values.global.env -}}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- with $comp.env -}}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- end -}}

{{/*}
Common namespace definition
*/}}
{{- define "lakerunner.namespace" -}}
{{- default .Release.Namespace .Values.global.namespaceOverride -}}
{{- end -}}

{{/*
Return only the indented key: value lines for .Values.global.annotations,
or nothing if the map is empty.
*/}}
{{- define "lakerunner.annotationPairs" -}}
{{- $ann := .Values.global.annotations -}}
{{- if and $ann (gt (len $ann) 0) -}}
{{ toYaml $ann | indent 2 }}
{{- end -}}
{{- end -}}

{{/*
"Smart" annotations helper: emits the header + pairs when non-empty.
*/}}
{{- define "lakerunner.annotations" -}}
{{- if and .Values.global.annotations (gt (len .Values.global.annotations) 0) -}}
annotations:
{{ include "lakerunner.annotationPairs" . }}
{{- end -}}
{{- end -}}

{{/*
"Smart" annotations helper with component-specific annotations support.
Usage: {{ include "lakerunner.annotationsWithComponent" (list . .Values.componentName.annotations) }}
*/}}
{{- define "lakerunner.annotationsWithComponent" -}}
  {{- $context := index . 0 -}}
  {{- $componentAnnotations := index . 1 | default dict -}}
  {{- $global := $context.Values.global.annotations | default dict -}}
  {{- $finalAnnotations := merge $componentAnnotations $global -}}
  {{- if gt (len $finalAnnotations) 0 -}}
annotations:
{{ toYaml $finalAnnotations | indent 2 }}
  {{- end -}}
{{- end -}}


{{/*
Return the secret name for the APIKeys.  If we have create true, we will prefix it with the release name.
*/}}
{{- define "lakerunner.apiKeysSecretName" -}}
{{- if .Values.apiKeys.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.apiKeys.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.apiKeys.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Return the secret name for the Cardinal API key.
*/}}
{{- define "lakerunner.cardinalApiKeySecretName" -}}
{{- printf "%s-%s" (include "lakerunner.fullname" .) "cardinal-api-key" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "lakerunner.cardinalTelemetryEnv" -}}
{{- if .Values.global.cardinal.apiKey }}
- name: cardinalhq-api-key
  valueFrom:
    secretKeyRef:
      name: {{ include "lakerunner.cardinalApiKeySecretName" . }}
      key: cardinalhq-api-key
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ if eq .Values.global.cardinal.env "test" }}"https://customer-intake-otelhttp.us-east-2.aws.test.cardinalhq.net"{{ else }}"https://otelhttp.intake.us-east-2.aws.cardinalhq.io"{{ end }}
- name: ENABLE_OTLP_TELEMETRY
  value: "true"
- name: OTEL_EXPORTER_OTLP_HEADERS
  valueFrom:
    secretKeyRef:
      name: {{ include "lakerunner.cardinalApiKeySecretName" . }}
      key: CARDINAL_API_HEADER
{{- end }}
{{- end }}

{{/*
Return the configmap name for the Storage Profiles.  If we have create true, we will prefix it with the release name.
*/}}
{{- define "lakerunner.storageProfilesConfigmapName" -}}
{{- if .Values.storageProfiles.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.storageProfiles.configmapName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.storageProfiles.configmapName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Return the secret name for the Database credentials.  If we have create true, we will prefix it with the release name.
*/}}
{{- define "lakerunner.databaseSecretName" -}}
{{- if .Values.database.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.database.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.database.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Return the secret name for the ConfigDB credentials.  If we have create true, we will prefix it with the release name.
*/}}
{{- define "lakerunner.configdbSecretName" -}}
{{- if .Values.configdb.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.configdb.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.configdb.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}


{{/*
Return the secret name for cloud provider credentials based on the configured provider.
*/}}
{{- define "lakerunner.cloudProviderSecretName" -}}
{{- if eq .Values.cloudProvider.provider "aws" }}
{{- if .Values.cloudProvider.aws.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.cloudProvider.aws.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.cloudProvider.aws.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- else if eq .Values.cloudProvider.provider "azure" }}
{{- if .Values.cloudProvider.azure.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.cloudProvider.azure.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.cloudProvider.azure.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- else if eq .Values.cloudProvider.provider "gcp" }}
{{- if .Values.cloudProvider.gcp.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.cloudProvider.gcp.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.cloudProvider.gcp.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return whether cloud provider credentials should be injected into pods.
*/}}
{{- define "lakerunner.injectCloudProviderCredentials" -}}
{{- $inject := false -}}
{{- if eq .Values.cloudProvider.provider "aws" -}}
{{- $inject = .Values.cloudProvider.aws.inject -}}
{{- else if eq .Values.cloudProvider.provider "azure" -}}
{{- $inject = .Values.cloudProvider.azure.inject -}}
{{- else if eq .Values.cloudProvider.provider "gcp" -}}
{{- $inject = .Values.cloudProvider.gcp.inject -}}
{{- end -}}
{{- $inject -}}
{{- end }}

{{/*
Return Spring profile based on cloud provider.
*/}}
{{- define "lakerunner.springProfile" -}}
{{- if eq .Values.cloudProvider.provider "azure" -}}
azure
{{- else -}}
aws
{{- end -}}
{{- end }}

{{/*
Return AWS region from cloudProvider configuration.
*/}}
{{- define "lakerunner.awsRegion" -}}
{{- if and (eq .Values.cloudProvider.provider "aws") .Values.cloudProvider.aws.region }}
{{- .Values.cloudProvider.aws.region }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}


{{/*
Merge two maps; keys in second take precedence.
Usage: {{ mergeOverwrite $map1 $map2 }}
*/}}
{{- define "lakerunner.mergeOverwrite" -}}
{{- $out := dict -}}
{{- range $k, $v := index . 0 -}}
  {{- $_ := set $out $k $v -}}
{{- end -}}
{{- range $k, $v := index . 1 -}}
  {{- $_ := set $out $k $v -}}
{{- end -}}
{{- $out -}}
{{- end -}}

{{/*
  Merge two maps (global + local), emit nodeSelector: if non-empty.
  args: [ globalMap, localMap ]
*/}}
{{- define "lakerunner.sched.nodeSelector" -}}
  {{- $args   := . -}}
  {{- $global := index $args 0 | default dict -}}
  {{- $local  := index $args 1 | default dict -}}
  {{- $m      := merge $local $global -}}
  {{- if gt (len $m) 0 -}}
nodeSelector:
{{ toYaml $m | indent 2 }}
  {{- end -}}
{{- end -}}


{{/*
  Merge global and local tolerations, emit tolerations: if non-empty.
  args: [ globalList, localList ]
*/}}
{{- define "lakerunner.sched.tolerations" -}}
  {{- $args   := . -}}
  {{- $global := index $args 0 | default list -}}
  {{- $local  := index $args 1 | default list -}}
  {{- $merged := concat $local $global -}}
  {{- if gt (len $merged) 0 -}}
tolerations:
{{ toYaml $merged | indent 2 }}
  {{- end -}}
{{- end -}}


{{/*
  Merge two affinity blocks, emit affinity: if non-empty.
  args: [ globalAffinity, localAffinity ]
*/}}
{{- define "lakerunner.sched.affinity" -}}
  {{- $args   := . -}}
  {{- $global := index $args 0 | default dict -}}
  {{- $local  := index $args 1 | default dict -}}
  {{- $m      := merge $local $global -}}
  {{- if gt (len $m) 0 -}}
affinity:
{{ toYaml $m | indent 2 }}
  {{- end -}}
{{- end -}}

{{/*
Generate the image tag to use.
Takes two arguments: component image config and root context
Priority: component.tag > global.image.tag > Chart.appVersion
Usage: {{ include "lakerunner.image.tag" (list .Values.componentName.image .) }}
*/}}
{{- define "lakerunner.image.tag" -}}
{{- $componentImage := index . 0 -}}
{{- $root := index . 1 -}}
{{- if and $componentImage.tag (ne $componentImage.tag "") -}}
{{- $componentImage.tag -}}
{{- else if and $root.Values.global.image.tag (ne $root.Values.global.image.tag "") -}}
{{- $root.Values.global.image.tag -}}
{{- else -}}
{{- $root.Chart.AppVersion -}}
{{- end -}}
{{- end -}}

{{/*
Generate the image repository to use.
Takes two arguments: component image config and root context
Priority: global.image.repository (if set) > component.repository
Only applies global override for lakerunner images (contains "lakerunner" in repository)
Usage: {{ include "lakerunner.image.repository" (list .Values.componentName.image .) }}
*/}}
{{- define "lakerunner.image.repository" -}}
{{- $componentImage := index . 0 -}}
{{- $root := index . 1 -}}
{{- if and $root.Values.global.image.repository (ne $root.Values.global.image.repository "") (contains "lakerunner" $componentImage.repository) -}}
{{- $root.Values.global.image.repository -}}
{{- else -}}
{{- $componentImage.repository -}}
{{- end -}}
{{- end -}}

{{/*
Generate the full image name for components.
Takes two arguments: component image config and root context
Usage: {{ include "lakerunner.image" (list .Values.componentName.image .) }}
*/}}
{{- define "lakerunner.image" -}}
{{- $componentImage := index . 0 -}}
{{- $root := index . 1 -}}
{{- $repository := include "lakerunner.image.repository" (list $componentImage $root) -}}
{{- $tag := include "lakerunner.image.tag" (list $componentImage $root) -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}

{{/*
Emit the LAKERUNNER_SCRATCH_DISK_SIZE_BYTES env var for scratch-using services.

Behavior (issue #783):
  - global.temporaryStorage.type == "ephemeral" (a real PersistentVolume via
    volumeClaimTemplate): emit NOTHING. The app falls back to statfs(), which is
    accurate on a dedicated PV. Setting an explicit size here would only cap the
    real volume.
  - otherwise (emptyDir backed by the node disk, with a sizeLimit): emit the
    sizeLimit converted to bytes so the app treats it as its authoritative scratch
    slice and stays within it. statfs on an emptyDir reports the whole node disk,
    not the pod's slice, so the explicit value is required.

The size value is the same one passed to lakerunner.ephemeralVolume, so the env
var always matches the emptyDir sizeLimit. Emits nothing if no size is set or it
parses to <= 0.

Takes two args:
  0: the root chart context
  1: the component's values block (must have .temporaryStorage.size)
Usage:
  {{ include "lakerunner.scratchDiskSizeEnv" (list $root $comp) }}
*/}}
{{- define "lakerunner.scratchDiskSizeEnv" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- if ne $root.Values.global.temporaryStorage.type "ephemeral" -}}
{{- $size := "" -}}
{{- if and $comp.temporaryStorage $comp.temporaryStorage.size -}}
  {{- $size = $comp.temporaryStorage.size -}}
{{- end -}}
{{- if $size -}}
{{- $bytes := include "lakerunner.parseMemoryToBytes" $size | int64 -}}
{{- if gt $bytes 0 }}
- name: LAKERUNNER_SCRATCH_DISK_SIZE_BYTES
  value: {{ $bytes | quote }}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Generate ephemeral volume configuration based on global settings.
Takes three arguments: volume name, storage size, and root context
Usage: {{ include "lakerunner.ephemeralVolume" (list "scratch" .Values.componentName.temporaryStorage.size .) }}
*/}}
{{- define "lakerunner.ephemeralVolume" -}}
{{- $volumeName := index . 0 -}}
{{- $storageSize := index . 1 -}}
{{- $root := index . 2 -}}
{{- if eq $root.Values.global.temporaryStorage.type "ephemeral" -}}
- name: {{ $volumeName }}
  ephemeral:
    volumeClaimTemplate:
      metadata:
        {{- if $root.Values.global.temporaryStorage.ephemeral.labels }}
        labels:
          {{- toYaml $root.Values.global.temporaryStorage.ephemeral.labels | nindent 10 }}
        {{- end }}
      spec:
        accessModes: [ "ReadWriteOnce" ]
        {{- if $root.Values.global.temporaryStorage.ephemeral.storageClassName }}
        storageClassName: {{ $root.Values.global.temporaryStorage.ephemeral.storageClassName | quote }}
        {{- end }}
        resources:
          requests:
            storage: {{ $storageSize | quote }}
{{- else -}}
- name: {{ $volumeName }}
  emptyDir:
    sizeLimit: {{ $storageSize | quote }}
{{- end -}}
{{- end -}}

{{/*
Generate ephemeral volume configuration without size limit based on global settings.
Takes two arguments: volume name and root context
Usage: {{ include "lakerunner.ephemeralVolumeBasic" (list "storage" .) }}
*/}}
{{- define "lakerunner.ephemeralVolumeBasic" -}}
{{- $volumeName := index . 0 -}}
{{- $root := index . 1 -}}
{{- if eq $root.Values.global.temporaryStorage.type "ephemeral" -}}
- name: {{ $volumeName }}
  ephemeral:
    volumeClaimTemplate:
      metadata:
        {{- if $root.Values.global.temporaryStorage.ephemeral.labels }}
        labels:
          {{- toYaml $root.Values.global.temporaryStorage.ephemeral.labels | nindent 10 }}
        {{- end }}
      spec:
        accessModes: [ "ReadWriteOnce" ]
        {{- if $root.Values.global.temporaryStorage.ephemeral.storageClassName }}
        storageClassName: {{ $root.Values.global.temporaryStorage.ephemeral.storageClassName | quote }}
        {{- end }}
        resources:
          requests:
            storage: "1Gi"
{{- else -}}
- name: {{ $volumeName }}
  emptyDir: {}
{{- end -}}
{{- end -}}

{{/*
Generate Azure workload identity token volume mount.
Always included when using Azure workload identity auth type.
*/}}
{{- define "lakerunner.azureTokenVolumeMount" -}}
{{- if and (eq .Values.cloudProvider.provider "azure") (eq .Values.cloudProvider.azure.authType "workload_identity") }}
- name: azure-identity-token
  mountPath: /var/run/secrets/azure/tokens
  readOnly: true
{{- end }}
{{- end }}

{{/*
Generate Azure workload identity token volume.
Always included when using Azure workload identity auth type.
*/}}
{{- define "lakerunner.azureTokenVolume" -}}
{{- if and (eq .Values.cloudProvider.provider "azure") (eq .Values.cloudProvider.azure.authType "workload_identity") }}
- name: azure-identity-token
  projected:
    sources:
    - serviceAccountToken:
        path: azure-identity-token
        audience: api://AzureADTokenExchange
        expirationSeconds: 3600
{{- end }}
{{- end }}

{{/*
Validate license configuration. Called from license-validation.yaml to fail early.
*/}}
{{- define "lakerunner.validateLicense" -}}
{{- if .Values.license.create }}
{{- if not .Values.license.data }}
{{- fail "license.data is required when license.create is true. Provide the raw license.json content or set license.create=false and specify an existing secret via license.secretName." }}
{{- end }}
{{- else }}
{{- if not .Values.license.secretName }}
{{- fail "license.secretName is required when license.create is false. Provide the name of an existing Kubernetes secret containing the license." }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Return the secret name for the license. If create is true, prefix with release name.
*/}}
{{- define "lakerunner.licenseSecretName" -}}
{{- if .Values.license.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.license.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.license.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Generate license volume mount. Always emitted — license is required.
Usage: {{ include "lakerunner.licenseVolumeMount" . }}
*/}}
{{- define "lakerunner.licenseVolumeMount" -}}
- name: license
  mountPath: /app/license
  readOnly: true
{{- end }}

{{/*
Generate license volume. Always emitted — license is required.
Usage: {{ include "lakerunner.licenseVolume" . }}
*/}}
{{- define "lakerunner.licenseVolume" -}}
- name: license
  secret:
    secretName: {{ include "lakerunner.licenseSecretName" . }}
{{- end }}

{{/*
Health probe configuration helper
Takes root context and service configuration and returns whether health probes should be enabled
Usage: {{ include "lakerunner.healthProbesEnabled" (list . .Values.serviceName) }}
*/}}
{{- define "lakerunner.healthProbesEnabled" -}}
{{- $root := index . 0 -}}
{{- $serviceConfig := index . 1 -}}
{{- if hasKey $serviceConfig "healthProbes" -}}
  {{- if not (eq $serviceConfig.healthProbes.enabled nil) -}}
    {{- $serviceConfig.healthProbes.enabled -}}
  {{- else -}}
    {{- $root.Values.global.healthProbes.enabled -}}
  {{- end -}}
{{- else -}}
  {{- $root.Values.global.healthProbes.enabled -}}
{{- end -}}
{{- end -}}

{{/*
Health probe template for lakerunner services
Generates standard liveness and readiness probes for lakerunner services
Usage: {{ include "lakerunner.healthProbes" (list . .Values.serviceName) }}
*/}}
{{- define "lakerunner.healthProbes" -}}
{{- $root := index . 0 -}}
{{- $serviceConfig := index . 1 -}}
{{- $portName := "healthcheck" -}}
{{- if gt (len .) 2 -}}{{- $portName = index . 2 -}}{{- end -}}
{{- if include "lakerunner.healthProbesEnabled" (list $root $serviceConfig) | eq "true" }}
livenessProbe:
  httpGet:
    path: /livez
    port: {{ $portName }}
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /readyz
    port: {{ $portName }}
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
{{- end -}}
{{- end -}}

{{/*
Parse Kubernetes memory value to bytes.
Supports: Ki, Mi, Gi, Ti, K, M, G, T (binary and decimal)
Usage: {{ include "lakerunner.parseMemoryToBytes" "1Gi" }}
*/}}
{{- define "lakerunner.parseMemoryToBytes" -}}
{{- $mem := . | toString -}}
{{- $value := 0 -}}
{{- $multiplier := 1 -}}
{{- if hasSuffix "Ki" $mem -}}
  {{- $value = trimSuffix "Ki" $mem | float64 -}}
  {{- $multiplier = 1024 -}}
{{- else if hasSuffix "Mi" $mem -}}
  {{- $value = trimSuffix "Mi" $mem | float64 -}}
  {{- $multiplier = 1048576 -}}
{{- else if hasSuffix "Gi" $mem -}}
  {{- $value = trimSuffix "Gi" $mem | float64 -}}
  {{- $multiplier = 1073741824 -}}
{{- else if hasSuffix "Ti" $mem -}}
  {{- $value = trimSuffix "Ti" $mem | float64 -}}
  {{- $multiplier = 1099511627776 -}}
{{- else if hasSuffix "K" $mem -}}
  {{- $value = trimSuffix "K" $mem | float64 -}}
  {{- $multiplier = 1000 -}}
{{- else if hasSuffix "M" $mem -}}
  {{- $value = trimSuffix "M" $mem | float64 -}}
  {{- $multiplier = 1000000 -}}
{{- else if hasSuffix "G" $mem -}}
  {{- $value = trimSuffix "G" $mem | float64 -}}
  {{- $multiplier = 1000000000 -}}
{{- else if hasSuffix "T" $mem -}}
  {{- $value = trimSuffix "T" $mem | float64 -}}
  {{- $multiplier = 1000000000000 -}}
{{- else -}}
  {{- $value = $mem | float64 -}}
{{- end -}}
{{- mulf $value $multiplier | int64 -}}
{{- end -}}

{{/*
Calculate GOMEMLIMIT based on memory limit.
Rules:
  - If memory > 1GiB: GOMEMLIMIT = total memory - 250MiB
  - If memory <= 1GiB: GOMEMLIMIT = 75% of memory
Returns value in MiB format (e.g., "3840MiB").
Usage: {{ include "lakerunner.calculateGomemlimit" "2Gi" }}
*/}}
{{- define "lakerunner.calculateGomemlimit" -}}
{{- $bytes := include "lakerunner.parseMemoryToBytes" . | int64 -}}
{{- $oneGiB := 1073741824 -}}
{{- $reserveMiB := 250 -}}
{{- $oneMiB := 1048576 -}}
{{- $totalMiB := divf $bytes $oneMiB | int64 -}}
{{- if gt $bytes $oneGiB -}}
  {{- $resultMiB := sub $totalMiB $reserveMiB -}}
  {{- printf "%dMiB" $resultMiB -}}
{{- else -}}
  {{- $resultMiB := mulf $totalMiB 0.75 | int64 -}}
  {{- printf "%dMiB" $resultMiB -}}
{{- end -}}
{{- end -}}

{{/*
Calculate GOGC based on memory limit.
Rules:
  - If memory <= 1GiB: GOGC = 50
  - If 1GiB < memory <= 2GiB: GOGC = 100
  - If memory > 2GiB: GOGC = 200
Usage: {{ include "lakerunner.calculateGogc" "2Gi" }}
*/}}
{{- define "lakerunner.calculateGogc" -}}
{{- $bytes := include "lakerunner.parseMemoryToBytes" . | int64 -}}
{{- $oneGiB := 1073741824 -}}
{{- $twoGiB := 2147483648 -}}
{{- if le $bytes $oneGiB -}}
50
{{- else if le $bytes $twoGiB -}}
100
{{- else -}}
200
{{- end -}}
{{- end -}}

{{/*
Check if GOMEMLIMIT is already set in env list.
Usage: {{ include "lakerunner.hasEnvVar" (list $envList "GOMEMLIMIT") }}
*/}}
{{- define "lakerunner.hasEnvVar" -}}
{{- $envList := index . 0 | default list -}}
{{- $varName := index . 1 -}}
{{- $found := false -}}
{{- range $envList -}}
  {{- if eq .name $varName -}}
    {{- $found = true -}}
  {{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}

{{/*
Generate Go runtime environment variables (GOMEMLIMIT, GOGC) based on resource limits.
Only sets values if not already provided by user in global.env or component.env.
Takes three args:
  0: the root chart context
  1: the component's values block (must have .resources.limits.memory)
  2: optional component env list
Usage: {{ include "lakerunner.goRuntimeEnv" (list . .Values.componentName .Values.componentName.env) }}
*/}}
{{- define "lakerunner.goRuntimeEnv" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- $compEnv := index . 2 | default list -}}
{{- $globalEnv := $root.Values.global.env | default list -}}
{{- $memLimit := "" -}}
{{- if and $comp.resources $comp.resources.limits $comp.resources.limits.memory -}}
  {{- $memLimit = $comp.resources.limits.memory -}}
{{- end -}}
{{- if $memLimit -}}
  {{- $hasGomemlimit := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "GOMEMLIMIT")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "GOMEMLIMIT")) "true") -}}
  {{- $hasGogc := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "GOGC")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "GOGC")) "true") -}}
  {{- if not $hasGomemlimit }}
- name: GOMEMLIMIT
  value: {{ include "lakerunner.calculateGomemlimit" $memLimit | quote }}
  {{- end }}
  {{- if not $hasGogc }}
- name: GOGC
  value: {{ include "lakerunner.calculateGogc" $memLimit | quote }}
  {{- end }}
{{- end -}}
{{- end -}}

{{/*
Generate Go + LKRN runtime environment variables for the process-* workers
(process-logs/metrics/traces). These no longer use DuckDB in-process (logs and
traces cannot); the heavy lifting is the `lkrn pack` subprocess, which keeps
decoded records in an in-memory buffer (LAKERUNNER_PACK_INMEM_BUFFER_MIB) and
spills to /scratch (via TMPDIR) only as overflow.

Memory budget split (process-* pods):
  GOMEMLIMIT                       ≈ 20% of container (clamped 256–1024 MiB)
  LAKERUNNER_PACK_INMEM_BUFFER_MIB ≈ 25% of container (clamped 256–1024 MiB)
  reserved                         ≈ rest — OS page (buffer) cache, pack spill
                                     round-trips, and RSS overage headroom.

Settings:
  - GOMEMLIMIT = clamp(20% of container, 256MiB..1024MiB)
  - GOGC = 100 (fixed)
  - LAKERUNNER_PACK_INMEM_BUFFER_MIB = clamp(25% of container, 256..1024) MiB
Takes three args:
  0: the root chart context
  1: the component's values block (must have .resources.limits.memory)
  2: optional component env list
Usage: {{ include "lakerunner.lkrnRuntimeEnv" (list . .Values.componentName .Values.componentName.env) }}
*/}}
{{- define "lakerunner.lkrnRuntimeEnv" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- $compEnv := index . 2 | default list -}}
{{- $globalEnv := $root.Values.global.env | default list -}}
{{- $memLimit := "" -}}
{{- if and $comp.resources $comp.resources.limits $comp.resources.limits.memory -}}
  {{- $memLimit = $comp.resources.limits.memory -}}
{{- end -}}
{{- if $memLimit -}}
  {{- $bytes := include "lakerunner.parseMemoryToBytes" $memLimit | int64 -}}
  {{- $oneMiB := 1048576 -}}
  {{- $totalMiB := divf $bytes $oneMiB | int64 -}}
  {{- $hasGomemlimit := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "GOMEMLIMIT")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "GOMEMLIMIT")) "true") -}}
  {{- $hasGogc := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "GOGC")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "GOGC")) "true") -}}
  {{- $hasLkrnBuffer := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "LAKERUNNER_PACK_INMEM_BUFFER_MIB")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "LAKERUNNER_PACK_INMEM_BUFFER_MIB")) "true") -}}
{{- if not $hasGomemlimit }}
{{- /* GOMEMLIMIT = 20% of container, clamped to [256, 1024] MiB */}}
{{- $gomemlimitMiB := mulf $totalMiB 0.20 | int64 -}}
{{- if lt $gomemlimitMiB 256 -}}{{- $gomemlimitMiB = 256 -}}{{- end -}}
{{- if gt $gomemlimitMiB 1024 -}}{{- $gomemlimitMiB = 1024 -}}{{- end }}
- name: GOMEMLIMIT
  value: {{ printf "%dMiB" $gomemlimitMiB | quote }}
{{- end }}
{{- if not $hasGogc }}
- name: GOGC
  value: "100"
{{- end }}
{{- if not $hasLkrnBuffer }}
{{- /* LKRN pack in-memory buffer = 25% of container, clamped [256, 1024] MiB */}}
{{- $lkrnMiB := mulf $totalMiB 0.25 | int64 -}}
{{- if lt $lkrnMiB 256 -}}{{- $lkrnMiB = 256 -}}{{- end -}}
{{- if gt $lkrnMiB 1024 -}}{{- $lkrnMiB = 1024 -}}{{- end }}
- name: LAKERUNNER_PACK_INMEM_BUFFER_MIB
  value: {{ $lkrnMiB | quote }}
{{- end }}
{{- end -}}
{{- include "lakerunner.scratchDiskSizeEnv" (list $root $comp) }}
{{- end -}}

{{/*
Generate query-worker-specific runtime environment variables.
Settings:
  - LAKERUNNER_DUCKDB_MEMORY_LIMIT = 50% of container memory (in MB)
  - GOMEMLIMIT = 75% of the remaining 50% (37.5% of total)
  - GOGC = calculated based on total memory
  - LAKERUNNER_DUCKDB_TEMP_DIRECTORY = /scratch
  - MALLOC_ARENA_MAX = 2 (cgo-heavy DuckDB workload — collapses glibc
                          per-thread arena fragmentation)
Takes three args:
  0: the root chart context
  1: the component's values block (must have .resources.limits.memory)
  2: optional component env list
Usage: {{ include "lakerunner.queryWorkerRuntimeEnv" (list . .Values.queryWorker .Values.queryWorker.env) }}
*/}}
{{- define "lakerunner.queryWorkerRuntimeEnv" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- $compEnv := index . 2 | default list -}}
{{- $globalEnv := $root.Values.global.env | default list -}}
{{- $memLimit := "" -}}
{{- if and $comp.resources $comp.resources.limits $comp.resources.limits.memory -}}
  {{- $memLimit = $comp.resources.limits.memory -}}
{{- end -}}
{{- if $memLimit -}}
  {{- $bytes := include "lakerunner.parseMemoryToBytes" $memLimit | int64 -}}
  {{- $oneMiB := 1048576 -}}
  {{- $totalMiB := divf $bytes $oneMiB | int64 -}}
  {{- $hasGomemlimit := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "GOMEMLIMIT")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "GOMEMLIMIT")) "true") -}}
  {{- $hasGogc := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "GOGC")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "GOGC")) "true") -}}
  {{- $hasDuckdbMemLimit := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "LAKERUNNER_DUCKDB_MEMORY_LIMIT")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "LAKERUNNER_DUCKDB_MEMORY_LIMIT")) "true") -}}
  {{- $hasDuckdbTempDir := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "LAKERUNNER_DUCKDB_TEMP_DIRECTORY")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "LAKERUNNER_DUCKDB_TEMP_DIRECTORY")) "true") -}}
  {{- $hasMallocArenaMax := or (eq (include "lakerunner.hasEnvVar" (list $globalEnv "MALLOC_ARENA_MAX")) "true") (eq (include "lakerunner.hasEnvVar" (list $compEnv "MALLOC_ARENA_MAX")) "true") -}}
{{- if not $hasGomemlimit }}
{{- /* GOMEMLIMIT = 75% of half the memory = 37.5% of total */}}
{{- $halfMiB := divf $totalMiB 2 | int64 -}}
{{- $gomemlimitMiB := mulf $halfMiB 0.75 | int64 }}
- name: GOMEMLIMIT
  value: {{ printf "%dMiB" $gomemlimitMiB | quote }}
{{- end }}
{{- if not $hasGogc }}
- name: GOGC
  value: {{ include "lakerunner.calculateGogc" $memLimit | quote }}
{{- end }}
{{- if not $hasDuckdbMemLimit }}
{{- /* DuckDB memory = 50% of total, in MB */}}
{{- $duckdbMB := divf $totalMiB 2 | int64 }}
- name: LAKERUNNER_DUCKDB_MEMORY_LIMIT
  value: {{ $duckdbMB | quote }}
{{- end }}
{{- if not $hasDuckdbTempDir }}
- name: LAKERUNNER_DUCKDB_TEMP_DIRECTORY
  value: "/scratch"
{{- end }}
{{- if not $hasMallocArenaMax }}
- name: MALLOC_ARENA_MAX
  value: "2"
{{- end }}
{{- end -}}
{{- include "lakerunner.scratchDiskSizeEnv" (list $root $comp) }}
{{- end -}}

{{/*
Inject common + component-specific env vars for query-worker.
Query-worker uses DuckDB for queries with specific memory tuning.
Takes two args:
  0: the root chart context (so we can call commonEnv with it)
  1: the component's values block (must have .env as a list)
Usage:
  {{ include "lakerunner.injectEnvQueryWorker" (list . .Values.queryWorker) | nindent 10 }}
*/}}
{{- define "lakerunner.injectEnvQueryWorker" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- include "lakerunner.commonEnv" $root | nindent 2 -}}
{{- include "lakerunner.queryWorkerRuntimeEnv" (list $root $comp $comp.env) | nindent 2 -}}
{{- include "lakerunner.tracesEnv" (list $root $comp) | nindent 2 -}}
{{- with $root.Values.global.env -}}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- with $comp.env -}}
{{ toYaml . | nindent 2 -}}
{{- end -}}
{{- end -}}

{{/*
Pod-level securityContext for a workload.
Shallow-merges global.podSecurityContext with an optional per-component override;
component fields win over global. Uses explicit `set` instead of sprig's `merge`
to avoid mergo's quirk where falsy zero values (false, 0, "") get overwritten.
Emits nothing when the resulting map is empty.
Usage:
  {{- include "lakerunner.podSecurityContext" (dict "root" . "override" .Values.grafana.podSecurityContext) | nindent 6 }}
Components without an override can omit the "override" key.
*/}}
{{- define "lakerunner.podSecurityContext" -}}
{{- $root := .root -}}
{{- $override := .override | default dict -}}
{{- $global := $root.Values.global.podSecurityContext | default dict -}}
{{- $merged := dict -}}
{{- range $k, $v := $global -}}
{{- $_ := set $merged $k $v -}}
{{- end -}}
{{- range $k, $v := $override -}}
{{- $_ := set $merged $k $v -}}
{{- end -}}
{{- if $merged }}
securityContext:
  {{- toYaml $merged | nindent 2 }}
{{- end -}}
{{- end }}

{{/*
Container-level securityContext for a container.
Same shallow-merge semantics as lakerunner.podSecurityContext.
Usage:
  {{- include "lakerunner.containerSecurityContext" (dict "root" . "override" .Values.grafana.containerSecurityContext) | nindent 8 }}
*/}}
{{- define "lakerunner.containerSecurityContext" -}}
{{- $root := .root -}}
{{- $override := .override | default dict -}}
{{- $global := $root.Values.global.containerSecurityContext | default dict -}}
{{- $merged := dict -}}
{{- range $k, $v := $global -}}
{{- $_ := set $merged $k $v -}}
{{- end -}}
{{- range $k, $v := $override -}}
{{- $_ := set $merged $k $v -}}
{{- end -}}
{{- if $merged }}
securityContext:
  {{- toYaml $merged | nindent 2 }}
{{- end -}}
{{- end }}

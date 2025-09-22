{{/*
Validate that HPA mode is not used - fail deployment if it is
*/}}
{{- define "lakerunner.validateScalingMode" -}}
{{- if eq .Values.global.autoscaling.mode "hpa" -}}
{{- fail "HPA scaling mode is no longer supported. Please use 'keda' or 'disabled' for autoscaling.mode" -}}
{{- end -}}
{{- end -}}

{{/*
Validate that legacy boxer configurations are not used
*/}}
{{- define "lakerunner.validateLegacyBoxerConfigs" -}}
{{- if or (hasKey .Values "boxerRollupMetrics") (hasKey .Values "boxerCompactMetrics") (hasKey .Values "boxerCompactLogs") (hasKey .Values "boxerCompactTraces") -}}
{{- fail "Legacy boxer configurations (boxerRollupMetrics, boxerCompactMetrics, boxerCompactLogs, boxerCompactTraces) are no longer supported. Please migrate to the new boxers.instances configuration. Example:\n\nboxers:\n  instances:\n    - name: metrics\n      tasks:\n        - compact-metrics\n        - rollup-metrics\n    - name: common\n      tasks:\n        - compact-logs\n        - compact-traces" -}}
{{- end -}}
{{- end -}}

{{/*
Validate that boxer instances do not have overlapping tasks
*/}}
{{- define "lakerunner.validateBoxerInstances" -}}
{{- if .Values.boxers.instances -}}
{{- $allTasks := list -}}
{{- range $instance := .Values.boxers.instances -}}
  {{- if not (hasKey $instance "name") -}}
    {{- fail "Boxer instance missing required 'name' field." -}}
  {{- end -}}
  {{- if not (hasKey $instance "tasks") -}}
    {{- fail (printf "Boxer instance '%s' missing required 'tasks' field." $instance.name) -}}
  {{- end -}}
  {{- if not $instance.tasks -}}
    {{- fail (printf "Boxer instance '%s' has no tasks assigned. Each instance must have at least one task." $instance.name) -}}
  {{- end -}}
  {{- range $task := $instance.tasks -}}
    {{- if has $task $allTasks -}}
      {{- fail (printf "Task '%s' is assigned to multiple boxer instances. Each task can only be assigned to one instance." $task) -}}
    {{- end -}}
    {{- $allTasks = append $allTasks $task -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

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

{{/*
Common environment variables
*/}}
{{- define "lakerunner.commonEnv" -}}
- name: LRDB_HOST
  value: {{ .Values.database.lrdb.host | quote }}
- name: LRDB_PORT
  value: {{ .Values.database.lrdb.port | quote }}
- name: LRDB_DBNAME
  value: {{ .Values.database.lrdb.name | quote }}
- name: LRDB_USER
  value: {{ .Values.database.lrdb.username | quote }}
- name: LRDB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "lakerunner.databaseSecretName" . }}
      key: {{ .Values.database.passwordKey }}
- name: LRDB_SSLMODE
  value: {{ .Values.database.lrdb.sslMode | quote }}
- name: CONFIGDB_HOST
  value: {{ .Values.configdb.lrdb.host | quote }}
- name: CONFIGDB_PORT
  value: {{ .Values.configdb.lrdb.port | quote }}
- name: CONFIGDB_DBNAME
  value: {{ .Values.configdb.lrdb.name | quote }}
- name: CONFIGDB_USER
  value: {{ .Values.configdb.lrdb.username | quote }}
- name: CONFIGDB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "lakerunner.configdbSecretName" . }}
      key: {{ .Values.configdb.passwordKey }}
- name: CONFIGDB_SSLMODE
  value: {{ .Values.configdb.lrdb.sslMode | quote }}
{{- if eq .Values.storageProfiles.source "config" }}
- name: STORAGE_PROFILE_FILE
  value: "/app/config/storage_profiles.yaml"
{{- end -}}
{{- end }}

{{/*
Inject common + component-specific env vars.
Takes two args:
  0: the root chart context (so we can call commonEnv with it)
  1: the component’s values block (must have .env as a list)
Usage:
  {{ include "lakerunner.injectEnv" (list . .Values.queryWorker) | nindent 10 }}
*/}}
{{- define "lakerunner.injectEnv" -}}
{{- $root := index . 0 -}}
{{- $comp := index . 1 -}}
{{- include "lakerunner.commonEnv" $root | nindent 2 -}}
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
Return the configmap name for the Kafka Topics.  If we have create true, we will prefix it with the release name.
*/}}
{{- define "lakerunner.kafkaTopicsConfigmapName" -}}
{{- if .Values.kafkaTopics.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.kafkaTopics.configmapName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.kafkaTopics.configmapName | trunc 63 | trimSuffix "-" }}
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
Return the secret name for DuckDB credentials.
*/}}
{{- define "lakerunner.duckdbSecretName" -}}
{{- if .Values.cloudProvider.duckdb.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.cloudProvider.duckdb.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.cloudProvider.duckdb.secretName | trunc 63 | trimSuffix "-" }}
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
Generate the full image name for components.
Takes two arguments: component image config and root context
Usage: {{ include "lakerunner.image" (list .Values.componentName.image .) }}
*/}}
{{- define "lakerunner.image" -}}
{{- $componentImage := index . 0 -}}
{{- $root := index . 1 -}}
{{- $tag := include "lakerunner.image.tag" (list $componentImage $root) -}}
{{- printf "%s:%s" $componentImage.repository $tag -}}
{{- end -}}

{{/*
Determine the autoscaling mode for a component.
Takes two arguments: component autoscaling config and root context
Returns the effective scaling mode: "hpa", "keda", or "disabled"
Usage: {{ include "lakerunner.autoscalingMode" (list .Values.componentName.autoscaling .) }}
*/}}
{{- define "lakerunner.autoscalingMode" -}}
{{- $componentAutoscaling := index . 0 -}}
{{- $root := index . 1 -}}
{{- if not $componentAutoscaling.enabled -}}
disabled
{{- else -}}
{{- $root.Values.global.autoscaling.mode -}}
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
Return whether DuckDB credentials should be injected into pods.
*/}}
{{- define "lakerunner.injectDuckdbCredentials" -}}
{{- if and .Values.cloudProvider.duckdb .Values.cloudProvider.duckdb.inject -}}
{{- "true" -}}
{{- else -}}
{{- "false" -}}
{{- end -}}
{{- end }}

{{/*
Return the secret name for the Kafka credentials. If we have create true, we will prefix it with the release name.
*/}}
{{- define "lakerunner.kafkaSecretName" -}}
{{- if .Values.kafka.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.kafka.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.kafka.secretName }}
{{- end }}
{{- end }}

{{/*
Generate Kafka environment variables.
This template injects Kafka configuration environment variables.
Usage: {{ include "lakerunner.kafkaEnv" . }}
*/}}
{{- define "lakerunner.kafkaEnv" -}}
# KAFKA_* variables
- name: LAKERUNNER_KAFKA_BROKERS
  value: {{ .Values.kafka.brokers | quote }}
- name: LAKERUNNER_KAFKA_TLS_ENABLED
  value: {{ .Values.kafka.tls.enabled | quote }}
{{- if .Values.kafka.sasl.enabled }}
- name: LAKERUNNER_KAFKA_SASL_ENABLED
  value: "true"
- name: LAKERUNNER_KAFKA_SASL_MECHANISM
  value: {{ .Values.kafka.sasl.mechanism | quote }}
- name: LAKERUNNER_KAFKA_SASL_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ include "lakerunner.kafkaSecretName" . }}
      key: {{ .Values.kafka.usernameKey }}
- name: LAKERUNNER_KAFKA_SASL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "lakerunner.kafkaSecretName" . }}
      key: {{ .Values.kafka.passwordKey }}
{{- else }}
- name: LAKERUNNER_KAFKA_SASL_ENABLED
  value: "false"
{{- end }}
{{- end }}

{{/*
Generate Kafka topics ConfigMap volume mount.
Usage: {{ include "lakerunner.kafkaTopicsVolumeMount" . }}
*/}}
{{- define "lakerunner.kafkaTopicsVolumeMount" -}}
{{- if .Values.kafkaTopics.create }}
- name: kafka-topics
  mountPath: /app/config/kafka_topics.yaml
  subPath: kafka_topics.yaml
  readOnly: true
{{- end }}
{{- end }}

{{/*
Generate Kafka topics ConfigMap volume.
Usage: {{ include "lakerunner.kafkaTopicsVolume" . }}
*/}}
{{- define "lakerunner.kafkaTopicsVolume" -}}
{{- if .Values.kafkaTopics.create }}
- name: kafka-topics
  configMap:
    name: {{ include "lakerunner.kafkaTopicsConfigmapName" . }}
{{- end }}
{{- end }}

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
{{- if include "lakerunner.healthProbesEnabled" (list $root $serviceConfig) | eq "true" }}
livenessProbe:
  httpGet:
    path: /livez
    port: healthcheck
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /readyz
    port: healthcheck
  initialDelaySeconds: 5
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
{{- end -}}
{{- end -}}

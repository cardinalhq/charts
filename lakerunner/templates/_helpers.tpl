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
Return the secret name for the tokens.  If we have create true, we will prefix it with the release name.
*/}}
{{- define "lakerunner.tokenSecretName" -}}
{{- if .Values.auth.token.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.auth.token.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.auth.token.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

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
Return the secret name for the AWS credentials.  If we have create true, we will prefix it with the release name.
*/}}
{{- define "lakerunner.awsSecretName" -}}
{{- if .Values.aws.create }}
{{- printf "%s-%s" (include "lakerunner.fullname" .) .Values.aws.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.aws.secretName | trunc 63 | trimSuffix "-" }}
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
  {{- $global := index $args 0 -}}
  {{- $local  := index $args 1 -}}
  {{- $m      := merge $global $local -}}
  {{- if gt (len $m) 0 -}}
nodeSelector:
{{ toYaml $m | indent 2 }}
  {{- end -}}
{{- end -}}


{{/*
  Pick local tolerations if set, else global, emit tolerations: if non-empty.
  args: [ globalList, localList ]
*/}}
{{- define "lakerunner.sched.tolerations" -}}
  {{- $args   := . -}}
  {{- $global := index $args 0 -}}
  {{- $local  := index $args 1 -}}
  {{- if gt (len $local) 0 -}}
tolerations:
{{ toYaml $local | indent 2 }}
  {{- else if gt (len $global) 0 -}}
tolerations:
{{ toYaml $global | indent 2 }}
  {{- end -}}
{{- end -}}


{{/*
  Merge two affinity blocks, emit affinity: if non-empty.
  args: [ globalAffinity, localAffinity ]
*/}}
{{- define "lakerunner.sched.affinity" -}}
  {{- $args   := . -}}
  {{- $global := index $args 0 -}}
  {{- $local  := index $args 1 -}}
  {{- $m      := merge $global $local -}}
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

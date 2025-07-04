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
  {{- /* pull in any user-defined global labels (or empty map) */ -}}
  {{- $global := .Values.global.labels | default dict -}}
  {{- /* start with chart name and selector labels */ -}}
  {{- $labels := merge
      (dict "helm.sh/chart" (include "lakerunner.chart" .))
      (include "lakerunner.selectorLabels" . | fromYaml)
  -}}
  {{- /* add app version if set */ -}}
  {{- if .Chart.AppVersion -}}
    {{- $labels = merge $labels (dict "app.kubernetes.io/version" (.Chart.AppVersion)) -}}
  {{- end -}}
  {{- /* always set managed-by */ -}}
  {{- $labels = merge $labels (dict "app.kubernetes.io/managed-by" .Release.Service) -}}
  {{- /* finally merge in globals (overrides defaults on conflict) */ -}}
  {{- $labels = merge $labels $global -}}
  {{- /* emit YAML block */ -}}
  {{- toYaml $labels -}}
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
{{- if .Values.global.serviceAccount.create }}
{{- default (include "lakerunner.fullname" .) .Values.global.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.global.serviceAccount.name }}
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
      name: {{ include "lakerunner.fullname" . }}-postgres
      key: password
- name: LRDB_SSLMODE
  value: {{ .Values.database.lrdb.sslMode | quote }}
- name: STORAGE_PROFILE_FILE
  value: "/app/config/storage_profiles.yaml"
{{- end }}

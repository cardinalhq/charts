{{/*
Expand the name of the chart.
*/}}
{{- define "conductor-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "conductor-server.fullname" -}}
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
{{- define "conductor-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "conductor-server.labels" -}}
  {{- $global := .Values.global.labels | default dict -}}
  {{- $labels := merge
      (dict "helm.sh/chart" (include "conductor-server.chart" .))
      (include "conductor-server.selectorLabels" . | fromYaml)
  -}}
  {{- if .Chart.AppVersion -}}
    {{- $labels = merge $labels (dict "app.kubernetes.io/version" (.Chart.AppVersion)) -}}
  {{- end -}}
  {{- $labels = merge $labels (dict "app.kubernetes.io/managed-by" .Release.Service) -}}
  {{- $labels = merge $labels $global -}}
  {{- toYaml $labels -}}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "conductor-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "conductor-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Render imagePullSecrets.
*/}}
{{- define "conductor-server.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Global annotations helper.
*/}}
{{- define "conductor-server.annotations" -}}
{{- if and .Values.global.annotations (gt (len .Values.global.annotations) 0) -}}
annotations:
  {{ toYaml .Values.global.annotations | indent 2 }}
{{- end -}}
{{- end -}}

{{/* ---- Image helpers ---- */}}

{{- define "conductor-server.mcpGateway.image" -}}
{{- $tag := .Values.mcpGateway.image.tag | default .Values.mcpGateway.appVersion -}}
{{- printf "%s:%s" .Values.mcpGateway.image.repository $tag -}}
{{- end -}}

{{- define "conductor-server.conductorServer.image" -}}
{{- $tag := .Values.conductorServer.image.tag | default .Values.conductorServer.appVersion -}}
{{- printf "%s:%s" .Values.conductorServer.image.repository $tag -}}
{{- end -}}

{{- define "conductor-server.maestroServer.image" -}}
{{- $tag := .Values.maestroServer.image.tag | default .Values.maestroServer.appVersion -}}
{{- printf "%s:%s" .Values.maestroServer.image.repository $tag -}}
{{- end -}}

{{/* ---- Secret name helpers ---- */}}

{{/*
MCP Gateway secret name. Prefixed with fullname when create: true.
*/}}
{{- define "conductor-server.mcpGateway.secretName" -}}
{{- if .Values.mcpGateway.secrets.create }}
{{- printf "%s-%s" (include "conductor-server.fullname" .) .Values.mcpGateway.secrets.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.mcpGateway.secrets.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Conductor Server secret name.
*/}}
{{- define "conductor-server.conductorServer.secretName" -}}
{{- if .Values.conductorServer.secrets.create }}
{{- printf "%s-%s" (include "conductor-server.fullname" .) .Values.conductorServer.secrets.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.conductorServer.secrets.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
LLM API keys secret name (used by conductor and maestro).
*/}}
{{- define "conductor-server.conductorServer.llmSecretName" -}}
{{- if .Values.conductorServer.llmSecrets.create }}
{{- printf "%s-%s" (include "conductor-server.fullname" .) .Values.conductorServer.llmSecrets.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.conductorServer.llmSecrets.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Maestro Server secret name.
*/}}
{{- define "conductor-server.maestroServer.secretName" -}}
{{- if .Values.maestroServer.secrets.create }}
{{- printf "%s-%s" (include "conductor-server.fullname" .) .Values.maestroServer.secrets.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.maestroServer.secrets.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Maestro Server LLM secret name.
*/}}
{{- define "conductor-server.maestroServer.llmSecretName" -}}
{{- if .Values.maestroServer.llmSecrets.create }}
{{- printf "%s-%s" (include "conductor-server.fullname" .) .Values.maestroServer.llmSecrets.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.maestroServer.llmSecrets.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/* ---- Service account helpers ---- */}}

{{- define "conductor-server.mcpGateway.serviceAccountName" -}}
{{- if .Values.mcpGateway.serviceAccount.create }}
{{- default (printf "%s-mcp-gateway" (include "conductor-server.fullname" .)) .Values.mcpGateway.serviceAccount.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.mcpGateway.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "conductor-server.conductorServer.serviceAccountName" -}}
{{- if .Values.conductorServer.serviceAccount.create }}
{{- default (printf "%s-conductor-server" (include "conductor-server.fullname" .)) .Values.conductorServer.serviceAccount.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.conductorServer.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "conductor-server.maestroServer.serviceAccountName" -}}
{{- if .Values.maestroServer.serviceAccount.create }}
{{- default (printf "%s-maestro-server" (include "conductor-server.fullname" .)) .Values.maestroServer.serviceAccount.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.maestroServer.serviceAccount.name }}
{{- end }}
{{- end }}

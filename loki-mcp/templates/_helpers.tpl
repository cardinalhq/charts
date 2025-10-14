{{/*
Expand the name of the chart.
*/}}
{{- define "loki-mcp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "loki-mcp.fullname" -}}
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
{{- define "loki-mcp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "loki-mcp.labels" -}}
helm.sh/chart: {{ include "loki-mcp.chart" . }}
{{ include "loki-mcp.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "loki-mcp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "loki-mcp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Return the secret name for the Cardinal API key
*/}}
{{- define "loki-mcp.cardinalSecretName" -}}
{{- if .Values.cardinal.secret.create }}
{{- printf "%s-%s" (include "loki-mcp.fullname" .) .Values.cardinal.secret.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.cardinal.secret.name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Generate the image name
*/}}
{{- define "loki-mcp.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}

{{/*
Validate required values
*/}}
{{- define "loki-mcp.validateValues" -}}
{{- if not .Values.loki.url }}
{{- fail "loki.url is required. Please provide the Loki server URL (e.g., http://loki.monitoring:3100)" }}
{{- end }}
{{- if not .Values.cardinal.apiKey }}
{{- fail "cardinal.apiKey is required. Please provide your CardinalHQ API key" }}
{{- end }}
{{- end }}

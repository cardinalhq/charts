{{/*
Expand the name of the chart.
*/}}
{{- define "lgtm-mcp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "lgtm-mcp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels (shared)
*/}}
{{- define "lgtm-mcp.labels" -}}
helm.sh/chart: {{ include "lgtm-mcp.chart" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Return the secret name for the Cardinal API key (shared)
*/}}
{{- define "lgtm-mcp.cardinalSecretName" -}}
{{- if .Values.cardinal.secret.create }}
{{- printf "%s-%s" .Release.Name .Values.cardinal.secret.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.cardinal.secret.name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
===================
Loki-specific helpers
===================
*/}}

{{/*
Loki fullname
*/}}
{{- define "lgtm-mcp.loki.fullname" -}}
{{- printf "%s-loki" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Loki labels
*/}}
{{- define "lgtm-mcp.loki.labels" -}}
{{ include "lgtm-mcp.labels" . }}
{{ include "lgtm-mcp.loki.selectorLabels" . }}
{{- end }}

{{/*
Loki selector labels
*/}}
{{- define "lgtm-mcp.loki.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lgtm-mcp.name" . }}-loki
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: loki
{{- end }}

{{/*
Loki image name
*/}}
{{- define "lgtm-mcp.loki.image" -}}
{{- $tag := .Values.loki.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.loki.image.repository $tag -}}
{{- end }}

{{/*
===================
Tempo-specific helpers
===================
*/}}

{{/*
Tempo fullname
*/}}
{{- define "lgtm-mcp.tempo.fullname" -}}
{{- printf "%s-tempo" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Tempo labels
*/}}
{{- define "lgtm-mcp.tempo.labels" -}}
{{ include "lgtm-mcp.labels" . }}
{{ include "lgtm-mcp.tempo.selectorLabels" . }}
{{- end }}

{{/*
Tempo selector labels
*/}}
{{- define "lgtm-mcp.tempo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lgtm-mcp.name" . }}-tempo
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: tempo
{{- end }}

{{/*
Tempo image name
*/}}
{{- define "lgtm-mcp.tempo.image" -}}
{{- $tag := .Values.tempo.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.tempo.image.repository $tag -}}
{{- end }}

{{/*
===================
Validation
===================
*/}}

{{/*
Validate required values
*/}}
{{- define "lgtm-mcp.validateValues" -}}
{{- if and .Values.loki.enabled (not .Values.loki.url) }}
{{- fail "loki.url is required when loki.enabled is true. Please provide the Loki server URL (e.g., http://loki.monitoring:3100)" }}
{{- end }}
{{- if and .Values.tempo.enabled (not .Values.tempo.url) }}
{{- fail "tempo.url is required when tempo.enabled is true. Please provide the Tempo server URL (e.g., http://tempo.tempo:3200)" }}
{{- end }}
{{- if not .Values.cardinal.apiKey }}
{{- fail "cardinal.apiKey is required. Please provide your CardinalHQ API key" }}
{{- end }}
{{- end }}

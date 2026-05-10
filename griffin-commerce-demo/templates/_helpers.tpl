{{/*
Expand the name of the chart.
*/}}
{{- define "griffin.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "griffin.fullname" -}}
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
Chart label string.
*/}}
{{- define "griffin.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "griffin.labels" -}}
helm.sh/chart: {{ include "griffin.chart" . }}
app.kubernetes.io/name: {{ include "griffin.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Resolve the container image: image.repository:image.tag, falling back to
.Chart.appVersion when image.tag is empty.
*/}}
{{- define "griffin.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{/*
Render imagePullSecrets when any are set.
*/}}
{{- define "griffin.imagePullSecrets" -}}
{{- if .Values.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Static list of backend services. Defined here (rather than in values) so
operators don't accidentally drop or rename a service the demo's inter-
service URLs depend on. Each entry: name, port, optional extraEnv, and
optional resources override (defaults match the kustomize base).
*/}}
{{- define "griffin.backends" -}}
- name: catalog
  port: 8080
- name: payment
  port: 8081
- name: cart
  port: 8082
  extraEnv:
    - name: CATALOG_SERVICE_URL
      value: "http://catalog:8080"
- name: images
  port: 8083
  resources:
    requests:
      memory: "256Mi"
      cpu: "100m"
    limits:
      memory: "512Mi"
      cpu: "300m"
- name: shipping
  port: 8084
- name: recommendations
  port: 8085
  extraEnv:
    - name: CATALOG_SERVICE_URL
      value: "http://catalog:8080"
{{- end -}}

{{/*
Default backend resources, used when a backend entry omits its own
resources override.
*/}}
{{- define "griffin.defaultBackendResources" -}}
requests:
  memory: "128Mi"
  cpu: "50m"
limits:
  memory: "256Mi"
  cpu: "200m"
{{- end -}}

{{/*
OTLP env vars for a single backend. Args: dict with `root` and `name`.
Emits nothing when no telemetry source is configured.
*/}}
{{- define "griffin.otelEnv" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $otel := $root.Values.otel | default dict -}}
{{- $endpoint := "" -}}
{{- if $otel.useHostIp -}}
{{- $endpoint = "http://$(HOST_IP):4318" -}}
{{- else if $otel.endpoint -}}
{{- $endpoint = $otel.endpoint -}}
{{- end -}}
{{- if $endpoint }}
{{- if $otel.useHostIp }}
- name: HOST_IP
  valueFrom:
    fieldRef:
      fieldPath: status.hostIP
{{- end }}
- name: OTEL_SERVICE_NAME
  value: {{ $name | quote }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ $endpoint | quote }}
- name: OTEL_INSECURE
  value: {{ $otel.insecure | default false | quote }}
{{- if $root.Values.chaos.enabled }}
- name: OTEL_METRIC_EXPORT_INTERVAL
  value: {{ $root.Values.chaos.metricExportIntervalMs | quote }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Chaos env vars for a single backend. Emits nothing when chaos is off.
Args: dict with `root` and `name`.
*/}}
{{- define "griffin.chaosEnv" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- if $root.Values.chaos.enabled }}
- name: CONTROLPLANE_URL
  value: "http://controlplane:8086"
{{- if eq $name "recommendations" }}
- name: RECS_REFRESH_INTERVAL
  value: {{ $root.Values.chaos.recsRefreshInterval | quote }}
{{- end }}
{{- end }}
{{- end -}}

{*
 Copyright (C) 2025-2026 CardinalHQ, Inc

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as
 published by the Free Software Foundation, version 3.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with this program. If not, see <http://www.gnu.org/licenses/>.
*}

{{- define "cardinal-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cardinal-gateway.fullname" -}}
{{- default (printf "%s-%s" .Release.Name (include "cardinal-gateway.name" .)) .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cardinal-gateway.labels" -}}
app.kubernetes.io/name: {{ include "cardinal-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: gateway
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "cardinal-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cardinal-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "cardinal-gateway.image" -}}
{{ .Values.image.repository }}:{{ default .Chart.AppVersion .Values.image.tag }}
{{- end -}}

{{- define "cardinal-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "cardinal-gateway.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

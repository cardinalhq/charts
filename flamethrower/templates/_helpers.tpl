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

{{- define "flamethrower.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "flamethrower.fullname" -}}
{{- default (printf "%s-%s" .Release.Name (include "flamethrower.name" .)) .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "flamethrower.labels" -}}
app.kubernetes.io/name: {{ include "flamethrower.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: load-generator
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "flamethrower.selectorLabels" -}}
app.kubernetes.io/name: {{ include "flamethrower.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "flamethrower.image" -}}
{{ .Values.image.repository }}:{{ default .Chart.AppVersion .Values.image.tag }}
{{- end -}}

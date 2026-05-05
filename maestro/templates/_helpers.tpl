{{/*
Expand the name of the chart.
*/}}
{{- define "maestro.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Render imagePullSecrets.
*/}}
{{- define "maestro.imagePullSecrets" -}}
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
{{- define "maestro.fullname" -}}
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
{{- define "maestro.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels, now including .Values.global.labels.
*/}}
{{- define "maestro.labels" -}}
  {{- $global := .Values.global.labels | default dict -}}
  {{- $labels := merge
      (dict "helm.sh/chart" (include "maestro.chart" .))
      (include "maestro.selectorLabels" . | fromYaml)
  -}}
  {{- if .Chart.AppVersion -}}
    {{- $labels = merge $labels (dict "app.kubernetes.io/version" (.Chart.AppVersion)) -}}
  {{- end -}}
  {{- $labels = merge $labels (dict "app.kubernetes.io/managed-by" .Release.Service) -}}
  {{- $labels = merge $labels $global -}}
  {{- toYaml $labels -}}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "maestro.selectorLabels" -}}
app.kubernetes.io/name: {{ include "maestro.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Return only the indented key: value lines for .Values.global.annotations,
or nothing if the map is empty.
*/}}
{{- define "maestro.annotationPairs" -}}
{{- $ann := .Values.global.annotations -}}
{{- if and $ann (gt (len $ann) 0) -}}
{{ toYaml $ann | indent 2 }}
{{- end -}}
{{- end -}}

{{/*
"Smart" annotations helper: emits the header + pairs when non-empty.
*/}}
{{- define "maestro.annotations" -}}
{{- if and .Values.global.annotations (gt (len .Values.global.annotations) 0) -}}
annotations:
{{ include "maestro.annotationPairs" . }}
{{- end -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "maestro.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "maestro.fullname" .) .Values.serviceAccount.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate the full image name (unified image for all components).
Priority: image.tag > Chart.appVersion
Usage: {{ include "maestro.image" . }}
*/}}
{{- define "maestro.image" -}}
{{- $tag := "" -}}
{{- if and .Values.image.tag (ne .Values.image.tag "") -}}
{{- $tag = .Values.image.tag -}}
{{- else -}}
{{- $tag = .Chart.AppVersion -}}
{{- end -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{/*
Return the secret name for the Database credentials. If we have create true, we will prefix it with the release name.
*/}}
{{- define "maestro.databaseSecretName" -}}
{{- if .Values.database.create }}
{{- printf "%s-%s" (include "maestro.fullname" .) .Values.database.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.database.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Database environment variables shared across components.
*/}}
{{- define "maestro.databaseEnv" -}}
- name: MAESTRO_DB_HOST
  value: {{ .Values.database.host | quote }}
- name: MAESTRO_DB_PORT
  value: {{ .Values.database.port | quote }}
- name: MAESTRO_DB_USER
  value: {{ .Values.database.username | quote }}
- name: MAESTRO_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "maestro.databaseSecretName" . }}
      key: {{ .Values.database.passwordKey }}
- name: MAESTRO_DB_NAME
  value: {{ .Values.database.name | quote }}
- name: MAESTRO_DB_SSLMODE
  value: {{ .Values.database.sslMode | quote }}
- name: MAESTRO_DATABASE_URL
  value: "postgresql://$(MAESTRO_DB_USER):$(MAESTRO_DB_PASSWORD)@$(MAESTRO_DB_HOST):$(MAESTRO_DB_PORT)/$(MAESTRO_DB_NAME)?sslmode=$(MAESTRO_DB_SSLMODE)"
{{- end }}

{{/*
Return the secret name for the Cardinal API key.
*/}}
{{- define "maestro.cardinalApiKeySecretName" -}}
{{- printf "%s-%s" (include "maestro.fullname" .) "cardinal-api-key" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Validate license configuration. Called from license-validation.yaml to fail early.
*/}}
{{- define "maestro.validateLicense" -}}
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
{{- define "maestro.licenseSecretName" -}}
{{- if .Values.license.create }}
{{- printf "%s-%s" (include "maestro.fullname" .) .Values.license.secretName | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.license.secretName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
License volume mount. Always emitted — license is required.
Usage: {{ include "maestro.licenseVolumeMount" . }}
*/}}
{{- define "maestro.licenseVolumeMount" -}}
- name: license
  mountPath: /app/license
  readOnly: true
{{- end }}

{{/*
License volume. Always emitted — license is required.
Usage: {{ include "maestro.licenseVolume" . }}
*/}}
{{- define "maestro.licenseVolume" -}}
- name: license
  secret:
    secretName: {{ include "maestro.licenseSecretName" . }}
{{- end }}

{{/*
OTLP env vars pointing at CardinalHQ's hosted intake. Emits nothing when
global.cardinal.apiKey is empty, so existing installs without telemetry
configuration are unaffected (and chart-test env-index assertions stay
stable). Both maestro (tracing.ts) and mcp-gateway (telemetry.go) read
OTEL_EXPORTER_OTLP_ENDPOINT and OTEL_EXPORTER_OTLP_HEADERS directly; no
extra gating env var is needed (lakerunner's ENABLE_OTLP_TELEMETRY is
lakerunner-specific and unused here).
*/}}
{{- define "maestro.cardinalTelemetryEnv" -}}
{{- if .Values.global.cardinal.apiKey }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ if eq .Values.global.cardinal.env "test" }}"https://customer-intake-otelhttp.us-east-2.aws.test.cardinalhq.net"{{ else }}"https://otelhttp.intake.us-east-2.aws.cardinalhq.io"{{ end }}
- name: OTEL_EXPORTER_OTLP_HEADERS
  valueFrom:
    secretKeyRef:
      name: {{ include "maestro.cardinalApiKeySecretName" . }}
      key: CARDINAL_API_HEADER
{{- end }}
{{- end }}

{{/*
  Merge two maps (global + local), emit nodeSelector: if non-empty.
  args: [ globalMap, localMap ]
*/}}
{{- define "maestro.sched.nodeSelector" -}}
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
{{- define "maestro.sched.tolerations" -}}
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
{{- define "maestro.sched.affinity" -}}
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
Pod-level securityContext for a workload.
Shallow-merges global.podSecurityContext with an optional per-component override;
component fields win over global. Uses explicit `set` instead of sprig's `merge`
to avoid mergo's quirk where falsy zero values (false, 0, "") get overwritten.
Emits nothing when the resulting map is empty.
Usage:
  {{- include "maestro.podSecurityContext" (dict "root" . "override" .Values.maestro.podSecurityContext) | nindent 6 }}
*/}}
{{- define "maestro.podSecurityContext" -}}
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
Same shallow-merge semantics as maestro.podSecurityContext.
*/}}
{{- define "maestro.containerSecurityContext" -}}
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

{{/*
Resolve the public base URL of the Maestro UI.
Precedence:
  1. .Values.maestro.baseUrl (explicit)
  2. derived from .Values.ingress.host with https when ingress.tls is
     non-empty, otherwise http
Returns empty string when neither is available.

Both branches normalize the input host: any leading scheme
(http://, https://) is stripped and any trailing slash is removed
before composition, so common operator typos like
`ingress.host: https://maestro.example.com/` produce a clean
`https://maestro.example.com` instead of `http://https://...//`.
*/}}
{{- define "maestro.baseUrl" -}}
{{- $explicit := default "" (dig "baseUrl" "" .Values.maestro) -}}
{{- if $explicit -}}
{{- $explicit | trimSuffix "/" -}}
{{- else if .Values.ingress.host -}}
{{- $scheme := "http" -}}
{{- if .Values.ingress.tls -}}
{{- $scheme = "https" -}}
{{- end -}}
{{- $host := .Values.ingress.host | trimPrefix "https://" | trimPrefix "http://" | trimSuffix "/" -}}
{{- printf "%s://%s" $scheme $host -}}
{{- end -}}
{{- end -}}

{{/*
Hostname-only view of maestro.baseUrl, with scheme and port stripped.
Used by the TLS sidecar's cert-init container to put the right CN/SAN
on its self-signed certificate.
*/}}
{{- define "maestro.baseUrlHost" -}}
{{- $base := include "maestro.baseUrl" . -}}
{{- $hostport := $base | trimPrefix "https://" | trimPrefix "http://" | trimSuffix "/" -}}
{{- regexReplaceAll ":[0-9]+$" $hostport "" -}}
{{- end -}}

{{/*
Validate maestro.tls inputs:
  * tls.enabled=true requires the resolved baseUrl to use https://, so the
    OIDC issuer URL the SPA hands to the browser matches the scheme the
    maestro Service actually serves.
  * Exactly one of three cert sources must be configured:
      - cert.autoGenerate=true (default, in-pod self-signed)
      - secretName (existing kubernetes.io/tls Secret)
      - cert.crt + cert.key (inline PEM, chart creates the Secret)
*/}}
{{- define "maestro.tlsValidate" -}}
{{- $tls := dig "tls" dict (.Values.maestro | default dict) -}}
{{- if dig "enabled" false $tls -}}
  {{- $base := include "maestro.baseUrlOrFail" . -}}
  {{- if not (hasPrefix "https://" $base) -}}
    {{- fail (printf "maestro.tls.enabled=true requires maestro.baseUrl to use https:// (got %q). Either set maestro.baseUrl to an https URL or set ingress.tls so the chart derives one." $base) -}}
  {{- end -}}
  {{- $autogen := dig "cert" "autoGenerate" true $tls -}}
  {{- $secret := dig "secretName" "" $tls -}}
  {{- $crt := dig "cert" "crt" "" $tls -}}
  {{- $key := dig "cert" "key" "" $tls -}}
  {{- if or (and $crt (not $key)) (and $key (not $crt)) -}}
    {{- fail "maestro.tls.cert: set both cert.crt and cert.key, or neither" -}}
  {{- end -}}
  {{- $inline := and $crt $key -}}
  {{- $count := 0 -}}
  {{- if $autogen -}}{{- $count = add $count 1 -}}{{- end -}}
  {{- if $secret -}}{{- $count = add $count 1 -}}{{- end -}}
  {{- if $inline -}}{{- $count = add $count 1 -}}{{- end -}}
  {{- if gt $count 1 -}}
    {{- fail "maestro.tls: set exactly one cert source — cert.autoGenerate=true, secretName, or cert.crt+cert.key (set cert.autoGenerate=false when using one of the BYO paths)" -}}
  {{- end -}}
  {{- if eq $count 0 -}}
    {{- fail "maestro.tls.enabled=true requires one cert source: cert.autoGenerate=true (default), a non-empty secretName, or cert.crt+cert.key" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Resolve the Secret name the TLS sidecar mounts. Returns:
  * .Values.maestro.tls.secretName when a user-provided Secret is referenced.
  * "<fullname>-maestro-tls-cert" when inline cert.crt+cert.key are set
    (the chart creates that Secret via templates/maestro-tls-secret.yaml).
  * empty string when autoGenerate is in effect (the volume is an emptyDir
    populated by the tls-init container).
*/}}
{{- define "maestro.tlsResolvedSecretName" -}}
{{- $tls := dig "tls" dict (.Values.maestro | default dict) -}}
{{- $secret := dig "secretName" "" $tls -}}
{{- $crt := dig "cert" "crt" "" $tls -}}
{{- $key := dig "cert" "key" "" $tls -}}
{{- if $secret -}}
{{- $secret -}}
{{- else if and $crt $key -}}
{{- printf "%s-maestro-tls-cert" (include "maestro.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Same as maestro.baseUrl but fails template rendering when the result is
empty. Use everywhere a dex-related URL is composed so a missing base
URL produces an explicit install-time error rather than a silent `/`
or `/dex` value that breaks at runtime.
*/}}
{{- define "maestro.baseUrlOrFail" -}}
{{- $base := include "maestro.baseUrl" . -}}
{{- if not $base -}}
{{- fail "dex.enabled=true requires either maestro.baseUrl to be set or ingress.host to be set so the Dex issuer URL can be derived" -}}
{{- end -}}
{{- $base -}}
{{- end -}}

{{/*
Fully qualified name of the bundled Dex Deployment / Service.
*/}}
{{- define "maestro.dexFullname" -}}
{{- printf "%s-dex" (include "maestro.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Defaulted view of .Values.dex. Returns a dict with the scalar/image
fields shared across the dex templates, falling back to documented
defaults when fields are absent. Per-template fields like staticUsers,
podSecurityContext, containerSecurityContext, nodeSelector, tolerations,
affinity, and resources are read directly from .Values.dex via inline
`dig` in the consuming template.

The point of routing through this helper is to make `--set dex.enabled=true`
sufficient on its own (every default lives in one place) and to keep
the values surface light enough that linters don't strip an empty
`dex:` block on every chart change.
*/}}
{{- define "maestro.dexConfig" -}}
{{- $d := .Values.dex | default dict -}}
{{- $img := dig "image" dict $d -}}
enabled: {{ dig "enabled" false $d }}
replicas: {{ dig "replicas" 1 $d }}
port: {{ dig "port" 5556 $d }}
pathPrefix: {{ dig "pathPrefix" "/dex" $d | quote }}
clientId: {{ dig "clientId" "maestro-ui" $d | quote }}
superadminGroup: {{ dig "superadminGroup" "maestro-superadmin" $d | quote }}
image:
  repository: {{ dig "repository" "ghcr.io/dexidp/dex" $img | quote }}
  tag: {{ dig "tag" "v2.41.1" $img | quote }}
  pullPolicy: {{ dig "pullPolicy" "IfNotPresent" $img | quote }}
{{- end -}}

{{/*
Validate that dex.enabled=true is paired with the inputs Dex actually
needs to be useful. Today:
  - non-empty staticUsers (otherwise Dex starts with no login options)
  - replicas <= 1 (storage.type=memory is per-pod; multiple replicas
    diverge on signing keys and session state, so login flows break
    on any pod that didn't issue the session cookie)

Call this from each dex template (and from maestro.oidcEnv) before
emitting any dex-dependent output.
*/}}
{{- define "maestro.dexValidate" -}}
{{- $d := .Values.dex | default dict -}}
{{- $users := dig "staticUsers" list $d -}}
{{- if not $users -}}
{{- fail "dex.enabled=true requires dex.staticUsers to be a non-empty list (otherwise the bundled Dex starts with no login options)" -}}
{{- end -}}
{{- $replicas := dig "replicas" 1 $d -}}
{{- if gt (int $replicas) 1 -}}
{{- fail "dex.replicas > 1 is incompatible with the bundled Dex's in-memory storage; sessions and signing keys diverge across pods. Use a single replica or replace the bundled Dex with an external OIDC provider for HA." -}}
{{- end -}}
{{- end -}}

{{/*
Browser-visible Dex issuer URL (used as OIDC_ISSUER_URL on maestro and as
the `issuer` field in Dex's own config). Path prefix included.
Fails template rendering when no base URL is available.
*/}}
{{- define "maestro.dexIssuerUrl" -}}
{{- $base := include "maestro.baseUrlOrFail" . -}}
{{- $cfg := include "maestro.dexConfig" . | fromYaml -}}
{{- printf "%s%s" $base $cfg.pathPrefix -}}
{{- end -}}

{{/*
SPA's redirect URI as Dex must whitelist it. Routed through
baseUrlOrFail so a misconfigured install fails loudly rather than
silently registering "/" as an allowed redirect — see auth-provider.tsx
which uses `redirect_uri: window.location.origin + "/"`.
*/}}
{{- define "maestro.dexRedirectUri" -}}
{{- printf "%s/" (include "maestro.baseUrlOrFail" .) -}}
{{- end -}}

{{/*
In-cluster JWKS URL for maestro to verify tokens against, bypassing the
ingress and any TLS termination. The `/keys` suffix is Dex's well-known
JWKS endpoint per its discovery doc; if Dex ever moves it, switch to
discovery-based resolution (fetch /.well-known/openid-configuration and
read jwks_uri) instead of hardcoding here.
*/}}
{{- define "maestro.dexInternalJwksUrl" -}}
{{- $svc := include "maestro.dexFullname" . -}}
{{- $cfg := include "maestro.dexConfig" . | fromYaml -}}
{{- printf "http://%s.%s.svc:%v%s/keys" $svc .Release.Namespace $cfg.port $cfg.pathPrefix -}}
{{- end -}}

{{/*
In-cluster Dex base URL with path prefix, used as DEX_PROXY_TARGET when
the maestro container reverse-proxies the Dex flow on behalf of the SPA.
This makes the install reachable through any path that reaches the
maestro Service alone — for example a single
`kubectl port-forward --address 0.0.0.0 svc/<release>-maestro 8080:4200`
on a bastion host — even when the cluster has no Ingress controller
doing /dex path-routing. Harmless when an Ingress is also routing /dex
directly: the Ingress path-match wins and requests never reach the
in-pod proxy.
*/}}
{{- define "maestro.dexInternalProxyTarget" -}}
{{- $svc := include "maestro.dexFullname" . -}}
{{- $cfg := include "maestro.dexConfig" . | fromYaml -}}
{{- printf "http://%s.%s.svc:%v%s" $svc .Release.Namespace $cfg.port $cfg.pathPrefix -}}
{{- end -}}

{{/*
OIDC + base URL env vars to inject into the maestro container when the
bundled Dex install is enabled. Emits nothing when dex.enabled is false.
Built-ins are emitted before the user's `maestro.env` list; Kubernetes
keeps the first occurrence on duplicate names, so the built-ins win
(matching the chart's existing convention exercised in env_test.yaml,
and locked in for OIDC_ISSUER_URL specifically by dex_test.yaml).
*/}}
{{- define "maestro.oidcEnv" -}}
{{- $cfg := include "maestro.dexConfig" . | fromYaml -}}
{{- if $cfg.enabled -}}
{{- include "maestro.dexValidate" . -}}
- name: OIDC_ISSUER_URL
  value: {{ include "maestro.dexIssuerUrl" . | quote }}
- name: OIDC_JWKS_URL
  value: {{ include "maestro.dexInternalJwksUrl" . | quote }}
- name: OIDC_AUDIENCE
  value: {{ $cfg.clientId | quote }}
- name: OIDC_CLIENT_ID
  value: {{ $cfg.clientId | quote }}
- name: OIDC_SUPERADMIN_GROUP
  value: {{ $cfg.superadminGroup | quote }}
- name: MAESTRO_BASE_URL
  value: {{ include "maestro.baseUrlOrFail" . | quote }}
{{- /* Optional in-pod reverse proxy for Dex — see dexInternalProxyTarget. */}}
{{- if dig "proxyEnabled" true (.Values.dex | default dict) }}
- name: DEX_PROXY_PATH
  value: {{ $cfg.pathPrefix | quote }}
- name: DEX_PROXY_TARGET
  value: {{ include "maestro.dexInternalProxyTarget" . | quote }}
{{- end }}
{{- end -}}
{{- end -}}


{{/*
process-* workers: one Deployment (and one HPA, see process-hpa.yaml) per
signal and role. The role table is fixed by the lakerunner binary
(LAKERUNNER_PROCESS_ROLE; kb/specs/work-orchestration/worker-split.md in the
lakerunner repo): a pod registers only its role's worklane actions, so every
action of a signal is owned by exactly one deployment and each stage scales on
its own CPU.

Values live under process.<signal>: signal-wide defaults (image, env,
resources, temporaryStorage, autoscaling, healthProbes, scheduling, security
contexts, labels, annotations) and per-role overrides under
process.<signal>.roles.<role>, deep-merged over the signal defaults. The pre-4.0
processLogs / processMetrics / processTraces blocks are still read as the
signal defaults so an existing values file upgrades with only a chart bump.
*/}}

{{/*
Role names per signal, in render order.
*/}}
{{- define "lakerunner.processRoles" -}}
{{- $roles := dict
    "logs"    (list "ingest" "compact")
    "metrics" (list "partition" "materialize" "compact" "rollup")
    "traces"  (list "ingest" "compact") -}}
{{- index $roles . | toJson -}}
{{- end -}}

{{/*
Signal-level values: process.<signal> with a legacy process<Signal> block (if
any) merged over it. The legacy block wins because the chart's own defaults
live under process.<signal>, and a values file written for 3.x must keep
producing the pods it produced before; delete the legacy block once its
settings have moved under process.<signal>.
Usage: {{ include "lakerunner.processSignalValues" (list . "logs") | fromYaml }}
*/}}
{{- define "lakerunner.processSignalValues" -}}
{{- $root := index . 0 -}}
{{- $signal := index . 1 -}}
{{- $legacyKey := printf "process%s" (title $signal) -}}
{{- $merged := dict -}}
{{- if $root.Values.process -}}
  {{- with index $root.Values.process $signal -}}
    {{- $merged = mergeOverwrite $merged (deepCopy .) -}}
  {{- end -}}
{{- end -}}
{{- with index $root.Values $legacyKey -}}
  {{- $merged = mergeOverwrite $merged (deepCopy .) -}}
{{- end -}}
{{- $merged | toYaml -}}
{{- end -}}

{{/*
Effective values for one role: signal defaults (minus the roles map) with the
role's own block merged over them.
Usage: {{ include "lakerunner.processRoleValues" (list . "metrics" "rollup") | fromYaml }}
*/}}
{{- define "lakerunner.processRoleValues" -}}
{{- $root := index . 0 -}}
{{- $signal := index . 1 -}}
{{- $role := index . 2 -}}
{{- $sig := include "lakerunner.processSignalValues" (list $root $signal) | fromYaml -}}
{{- $roles := $sig.roles | default dict -}}
{{- $_ := unset $sig "roles" -}}
{{- $_ = unset $sig "partitions" -}}
{{- $_ = unset $sig "replicas" -}}
{{- $v := $sig -}}
{{- with index $roles $role -}}
  {{- $v = mergeOverwrite $v (deepCopy .) -}}
{{- end -}}
{{- $v | toYaml -}}
{{- end -}}

{{/*
materialize may not out-scale the partition count it will own once pre-ingest
partitioning lands. An inherited (signal-level) maxReplicas is clamped; one set
explicitly on the role above the partition count fails the render.
Usage: {{ include "lakerunner.processMaxReplicas" (list . "metrics" "materialize" $v) }}
*/}}
{{- define "lakerunner.processMaxReplicas" -}}
{{- $root := index . 0 -}}
{{- $signal := index . 1 -}}
{{- $role := index . 2 -}}
{{- $v := index . 3 -}}
{{- $as := $v.autoscaling | default dict -}}
{{- $max := $as.maxReplicas | default 1 | int -}}
{{- if and (eq $signal "metrics") (eq $role "materialize") -}}
  {{- $sig := include "lakerunner.processSignalValues" (list $root $signal) | fromYaml -}}
  {{- $partitions := $sig.partitions | default 0 | int -}}
  {{- if gt $partitions 0 -}}
    {{- $explicit := dig "roles" "materialize" "autoscaling" "maxReplicas" nil $sig -}}
    {{- if and (ne $explicit nil) (gt (int $explicit) $partitions) -}}
      {{- fail (printf "process.metrics.roles.materialize.autoscaling.maxReplicas (%d) exceeds process.metrics.partitions (%d): the materialize role cannot run more replicas than there are partitions" (int $explicit) $partitions) -}}
    {{- end -}}
    {{- if gt $max $partitions -}}{{- $max = $partitions -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- $max -}}
{{- end -}}

{{/*
One process-<signal>-<role> Deployment.
Usage: {{ include "lakerunner.processWorker" (dict "root" . "signal" "logs" "role" "ingest") }}
*/}}
{{- define "lakerunner.processWorker" -}}
{{- $root := .root -}}
{{- $signal := .signal -}}
{{- $role := .role -}}
{{- $v := include "lakerunner.processRoleValues" (list $root $signal $role) | fromYaml -}}
{{- $component := printf "process-%s-%s" $signal $role -}}
{{- $name := printf "%s-%s" (include "lakerunner.fullname" $root) $component -}}
{{- $image := $v.image | default dict -}}
{{- $agentSessions := dict -}}
{{- if and (eq $signal "logs") $v.agentSessions -}}{{- $agentSessions = $v.agentSessions -}}{{- end -}}
{{- $rulesCM := and $agentSessions.enabled $agentSessions.rulesConfigMap $agentSessions.rulesConfigMap.enabled -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    {{- include "lakerunner.labelsWithComponent" (list $root $v.labels) | nindent 4 }}
    app.kubernetes.io/component: {{ $component }}
    lakerunner.cardinalhq.io/signal: {{ $signal }}
    lakerunner.cardinalhq.io/role: {{ $role }}
  {{ include "lakerunner.annotationsWithComponent" (list $root $v.annotations) | nindent 2 }}
spec:
  selector:
    matchLabels:
      {{- include "lakerunner.selectorLabels" $root | nindent 6 }}
      app.kubernetes.io/component: {{ $component }}
  template:
    metadata:
      labels:
        {{- include "lakerunner.labelsWithComponent" (list $root $v.labels) | nindent 8 }}
        app.kubernetes.io/component: {{ $component }}
        lakerunner.cardinalhq.io/signal: {{ $signal }}
        lakerunner.cardinalhq.io/role: {{ $role }}
        {{- if eq $root.Values.cloudProvider.azure.authType "workload_identity" }}
        azure.workload.identity/use: "true"
        {{- end }}
      {{- include "lakerunner.annotationsWithComponent" (list $root $v.annotations) | nindent 6 }}
    spec:
      serviceAccountName: {{ include "lakerunner.serviceAccountName" $root }}
      {{- include "lakerunner.podSecurityContext" (dict "root" $root "override" $v.podSecurityContext) | nindent 6 }}
      {{- include "lakerunner.imagePullSecrets" $root | nindent 6 }}
      containers:
      - name: {{ $component }}
        {{- include "lakerunner.containerSecurityContext" (dict "root" $root "override" $v.containerSecurityContext) | nindent 8 }}
        image: {{ include "lakerunner.image" (list $image $root) }}
        imagePullPolicy: {{ $image.pullPolicy | default $root.Values.global.image.pullPolicy }}
        command: ["/app/bin/lakerunner"]
        args: ["process-{{ $signal }}"]
        ports:
          - name: healthcheck
            containerPort: {{ $root.Values.global.healthProbes.healthcheckPort }}
            protocol: TCP
        env:
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
          - name: POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: POD_IP
            valueFrom:
              fieldRef:
                fieldPath: status.podIP
          - name: OTEL_SERVICE_NAME
            value: {{ $name }}
          - name: LAKERUNNER_PROCESS_ROLE
            value: {{ $role | quote }}
          {{- include "lakerunner.scratchEnv" $root | nindent 10 }}
          {{- if $agentSessions.enabled }}
          # Enable the in-process agent-sessions sub-processor (taps
          # claude-code records from each ingested bundle, UPSERTs into
          # the agent_sessions table). The binary runs it only in the
          # ingest role. See kb/specs/agent-analytics in the lakerunner repo.
          - name: LAKERUNNER_AGENT_SESSIONS_ENABLE
            value: "true"
          {{- if $rulesCM }}
          - name: AGENT_SESSIONS_RULES_PATH
            value: /etc/lakerunner/agent-sessions-rules.yaml
          {{- end }}
          {{- end }}
          {{- if eq $root.Values.cloudProvider.provider "azure" }}
          - name: AZURE_AUTH_TYPE
            value: {{ $root.Values.cloudProvider.azure.authType | quote }}
          {{- end }}
          {{- if and (eq $signal "logs") $root.Values.features.logEmbeddedC2Index }}
          - name: LAKERUNNER_FEATURES_LOG_EMBEDDED_C2_INDEX
            value: "true"
          {{- end }}
          {{- include "lakerunner.injectEnvDuckdb" (list $root $v) | nindent 8 }}
          {{- include "lakerunner.cardinalTelemetryEnv" $root | nindent 10 }}
        {{- if eq (include "lakerunner.injectCloudProviderCredentials" $root) "true" }}
        envFrom:
          - secretRef:
              name: {{ include "lakerunner.cloudProviderSecretName" $root }}
        {{- end }}
        {{- include "lakerunner.healthProbes" (list $root $v) | nindent 8 }}
        {{- if $root.Values.global.resources.enabled }}
        resources:
          {{- toYaml $v.resources | nindent 10 }}
        {{- end }}
        volumeMounts:
        {{- if eq $root.Values.storageProfiles.source "config" }}
        - name: storage-profiles
          mountPath: /app/config/storage_profiles.yaml
          subPath: storage_profiles.yaml
          readOnly: true
        {{- end }}
        - name: scratch
          mountPath: /scratch
        {{- if $rulesCM }}
        - name: agent-sessions-rules
          mountPath: /etc/lakerunner/agent-sessions-rules.yaml
          subPath: rules.yaml
          readOnly: true
        {{- end }}
        {{- include "lakerunner.azureTokenVolumeMount" $root | nindent 8 }}
        {{- include "lakerunner.licenseVolumeMount" $root | nindent 8 }}
      {{- include "lakerunner.sched.nodeSelector" (list $root.Values.global.nodeSelector $v.nodeSelector) | nindent 6 }}
      {{- include "lakerunner.sched.tolerations"  (list $root.Values.global.tolerations  $v.tolerations)  | nindent 6 }}
      {{- include "lakerunner.sched.affinity"     (list $root.Values.global.affinity     $v.affinity)     | nindent 6 }}
      volumes:
      {{- include "lakerunner.ephemeralVolume" (list "scratch" $v.temporaryStorage.size $root) | nindent 6 }}
      {{- if eq $root.Values.storageProfiles.source "config" }}
      - name: storage-profiles
        configMap:
          name: {{ include "lakerunner.storageProfilesConfigmapName" $root }}
      {{- end }}
      {{- if $rulesCM }}
      - name: agent-sessions-rules
        configMap:
          name: {{ $agentSessions.rulesConfigMap.name | default (printf "%s-agent-sessions-rules" (include "lakerunner.fullname" $root)) }}
      {{- end }}
      {{- include "lakerunner.azureTokenVolume" $root | nindent 6 }}
      {{- include "lakerunner.licenseVolume" $root | nindent 6 }}
{{- end -}}

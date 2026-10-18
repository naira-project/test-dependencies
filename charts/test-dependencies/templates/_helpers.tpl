{{- define "deps.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "deps.stableLabels" . }}
{{- end -}}

{{- /* deps.labels without the chart version, for specs hashed into a name. */}}
{{- define "deps.stableLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: naira
naira.io/tier: dependencies
{{- end -}}

{{- /* PSS restricted, minus runAsUser and readOnlyRootFilesystem (per image). */}}
{{- define "deps.securityContext" -}}
allowPrivilegeEscalation: false
capabilities: {drop: [ALL]}
runAsNonRoot: true
seccompProfile: {type: RuntimeDefault}
{{- end -}}

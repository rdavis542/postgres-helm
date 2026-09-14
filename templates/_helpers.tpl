{{- define "postgres.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "postgres.labels" -}}
app: {{ include "postgres.name" . }}
app.kubernetes.io/name: {{ include "postgres.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

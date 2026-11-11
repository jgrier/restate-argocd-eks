{{/* Version suffix when versioning is on: versioning.version, else image.tag, made DNS-safe. */}}
{{- define "greeter.version" -}}
{{- .Values.versioning.version | default .Values.image.tag | replace "." "-" | replace "_" "-" | lower | trunc 20 | trimSuffix "-" -}}
{{- end }}

{{/* Name of the Deployment/Service: <release>-<version> with versioning, else <release>. */}}
{{- define "greeter.name" -}}
{{- if .Values.versioning.enabled -}}
{{ .Release.Name }}-{{ include "greeter.version" . }}
{{- else -}}
{{ .Release.Name }}
{{- end -}}
{{- end }}

{{- define "greeter.labels" -}}
app: {{ .Release.Name }}
{{- if .Values.versioning.enabled }}
restate.dev/version: {{ include "greeter.version" . | quote }}
{{- end }}
{{- end }}

{{/* Versioned objects outlive their version in git: Argo must not prune them
     or count them as drift. The release Job removes them once drained. */}}
{{- define "greeter.annotations" -}}
{{- if .Values.versioning.enabled }}
argocd.argoproj.io/sync-options: Prune=false
argocd.argoproj.io/compare-options: IgnoreExtraneous
{{- end }}
{{- end }}

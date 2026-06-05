{{- define "ros2-overlay.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "ros2-overlay.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "ros2-overlay.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "ros2-overlay.labels" -}}
app.kubernetes.io/name: {{ include "ros2-overlay.name" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
overlayVersion — the semver-ish identifier used as a subdirectory inside the
PVC and as the URL path served by the overlay-server. Defaults to the chart
version (Chart.yaml `version`) so a `helm rollback` automatically remounts
the previous overlay subdir without re-downloading the carrier image.

Override via .Values.overlayVersion only if you want to decouple the overlay
content from the chart version (rare).
*/}}
{{- define "ros2-overlay.overlayVersion" -}}
{{- default .Chart.Version .Values.overlayVersion -}}
{{- end }}

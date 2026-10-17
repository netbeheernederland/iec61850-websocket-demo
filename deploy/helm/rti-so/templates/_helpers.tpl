{{/* Chart name, truncated to the 63 characters of a DNS label */}}
{{- define "rti-so.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified name, unique per release: the release name, prefixed with
the chart name unless it already contains it (release site-a -> rti-so-site-a).
*/}}
{{- define "rti-so.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" $name .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "rti-so.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rti-so.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "rti-so.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "rti-so.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: rti-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
The plugin configuration (PLUGINS) as JSON: the IO sidecar as io, then
.Values.plugins. Empty when there are none.
*/}}
{{- define "rti-so.pluginsJson" -}}
{{- $plugins := list }}
{{- if .Values.io.enabled }}
{{- $plugins = append $plugins (dict "name" "io" "url" (printf "http://localhost:%v/plugin" .Values.io.port) "settings" .Values.io.settings) }}
{{- end }}
{{- $plugins = concat $plugins .Values.plugins }}
{{- if $plugins }}
{{- $hostUrl := .Values.pluginHostUrl | default (printf "http://localhost:%v" .Values.port) }}
{{- dict "host_url" $hostUrl "plugins" $plugins | toJson }}
{{- end }}
{{- end }}

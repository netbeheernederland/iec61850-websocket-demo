{{/* Chart name, truncated to the 63 characters of a DNS label */}}
{{- define "rti-fsp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified name, unique per release: the release name, prefixed with
the chart name unless it already contains it (release cp1 -> rti-fsp-cp1).
*/}}
{{- define "rti-fsp.fullname" -}}
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

{{- define "rti-fsp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rti-fsp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "rti-fsp.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "rti-fsp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: rti-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
rti-demo/cp: {{ .Values.cp | quote }}
{{- end }}

{{/* File name of the model in /models, or empty for the built-in model */}}
{{- define "rti-fsp.modelFile" -}}
{{- if .Values.model.content }}
{{- default "model.py" .Values.model.file }}
{{- else }}
{{- .Values.model.file }}
{{- end }}
{{- end }}

{{/* The model's source: inline content, else the bundled file */}}
{{- define "rti-fsp.modelContent" -}}
{{- if .Values.model.content }}
{{- .Values.model.content }}
{{- else if .Values.model.file }}
{{- $content := .Files.Get (printf "models/%s" .Values.model.file) }}
{{- if not $content }}
{{- fail (printf "model.file %q is not in the chart's models/ directory; give its source as model.content instead" .Values.model.file) }}
{{- end }}
{{- $content }}
{{- end }}
{{- end }}

{{/*
The plugin configuration (PLUGINS) as JSON: the dr-panel sidecar as dr_panel, then
.Values.plugins. Empty when there are none.
*/}}
{{- define "rti-fsp.pluginsJson" -}}
{{- $plugins := list }}
{{- if .Values.drPanel.enabled }}
{{- $plugins = append $plugins (dict "name" "dr_panel" "url" (printf "http://localhost:%v/plugin" .Values.drPanel.port) "settings" .Values.drPanel.settings) }}
{{- end }}
{{- $plugins = concat $plugins .Values.plugins }}
{{- if $plugins }}
{{- $hostUrl := .Values.pluginHostUrl | default (printf "http://localhost:%v" .Values.port) }}
{{- dict "host_url" $hostUrl "plugins" $plugins | toJson }}
{{- end }}
{{- end }}

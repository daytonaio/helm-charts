{{/* vim: set filetype=mustache: */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "daytona.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "daytona.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- $releaseName := regexReplaceAll "(-?[^a-z\\d\\-])+-?" (lower .Release.Name) "-" -}}
{{- if contains $name $releaseName -}}
{{- $releaseName | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" $releaseName $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "daytona.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "daytona.labels" -}}
helm.sh/chart: {{ include "daytona.chart" . }}
{{ include "daytona.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "daytona.selectorLabels" -}}
app.kubernetes.io/name: {{ include "daytona.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "daytona.serviceAccountName" -}}
{{- $service := .service | default "" -}}
{{- if $service -}}
{{- $serviceConfig := index .Values.services $service -}}
{{- if $serviceConfig.serviceAccount.create }}
{{- $normalizedService := $service -}}
{{- if eq $service "sshGateway" -}}
  {{- $normalizedService = "ssh-gateway" -}}
{{- else if eq $service "snapshotManager" -}}
  {{- $normalizedService = "snapshot-manager" -}}
{{- end -}}
{{- default (printf "%s-%s" (include "daytona.fullname" .) $normalizedService) $serviceConfig.serviceAccount.name }}
{{- else }}
{{- default "default" $serviceConfig.serviceAccount.name }}
{{- end }}
{{- else }}
{{- default "default" "" }}
{{- end }}
{{- end }}

{{/*
Allow the release namespace to be overridden for multi-namespace deployments in combined charts.
*/}}
{{- define "daytona.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create the name of the config map
*/}}
{{- define "daytona.configMapName" -}}
{{- printf "%s-config" (include "daytona.fullname" .) }}
{{- end }}

{{/*
Create the name of the secret
*/}}
{{- define "daytona.secretName" -}}
{{- printf "%s-secret" (include "daytona.fullname" .) }}
{{- end }}

{{/*
Get image registry (use global if set, otherwise service-specific)
*/}}
{{- define "daytona.imageRegistry" -}}
{{- if .Values.global.imageRegistry -}}
{{- .Values.global.imageRegistry -}}
{{- else if .serviceRegistry -}}
{{- .serviceRegistry -}}
{{- end -}}
{{- end }}

{{/*
Renders a value that contains template perhaps with scope if the scope is present.
Usage:
{{ include "daytona.tplvalues.render" ( dict "value" .Values.path.to.the.Value "context" $ ) }}
{{ include "daytona.tplvalues.render" ( dict "value" .Values.path.to.the.Value "context" $ "scope" $app ) }}
*/}}
{{- define "daytona.tplvalues.render" -}}
{{- $value := typeIs "string" .value | ternary .value (.value | toYaml) }}
{{- if contains "{{" (toJson .value) }}
  {{- if .scope }}
      {{- tpl (cat "{{- with $.RelativeScope -}}" $value "{{- end }}") (merge (dict "RelativeScope" .scope) .context) }}
  {{- else }}
    {{- tpl $value .context }}
  {{- end }}
{{- else }}
    {{- $value }}
{{- end }}
{{- end -}}

{{/*
Extract protocol from proxyUrl.
Example: "https://proxy.example.com:4000" -> "https"
Usage:
{{ include "daytona.proxyUrl.protocol" . }}
*/}}
{{- define "daytona.proxyUrl.protocol" -}}
{{- $proxyUrl := required "proxyUrl is required" .Values.proxyUrl -}}
{{- regexReplaceAll "://.*" $proxyUrl "" -}}
{{- end -}}

{{/*
Extract hostname from proxyUrl (without protocol and port).
Example: "https://proxy.example.com:4000" -> "proxy.example.com"
Usage:
{{ include "daytona.proxyUrl.hostname" . }}
*/}}
{{- define "daytona.proxyUrl.hostname" -}}
{{- $proxyUrl := required "proxyUrl is required" .Values.proxyUrl -}}
{{- $withoutProtocol := regexReplaceAll "^[a-z]+://" $proxyUrl "" -}}
{{- regexReplaceAll ":.*" $withoutProtocol "" -}}
{{- end -}}

{{/*
Extract port from proxyUrl. Returns empty string if no port specified.
Example: "https://proxy.example.com:4000" -> "4000"
Example: "https://proxy.example.com" -> ""
Usage:
{{ include "daytona.proxyUrl.port" . }}
*/}}
{{- define "daytona.proxyUrl.port" -}}
{{- $proxyUrl := required "proxyUrl is required" .Values.proxyUrl -}}
{{- $withoutProtocol := regexReplaceAll "^[a-z]+://" $proxyUrl "" -}}
{{- if contains ":" $withoutProtocol -}}
{{- regexReplaceAll "^[^:]+:" $withoutProtocol "" -}}
{{- end -}}
{{- end -}}

{{/*
Extract base domain from proxyUrl by stripping the first subdomain (e.g., "proxy.").
Example: "https://proxy.example.com:4000" -> "example.com"
Example: "https://proxy.sub.example.com:4000" -> "sub.example.com"
Usage:
{{ include "daytona.proxyUrl.baseDomain" . }}
*/}}
{{- define "daytona.proxyUrl.baseDomain" -}}
{{- $hostname := include "daytona.proxyUrl.hostname" . -}}
{{- regexReplaceAll "^[^.]+\\." $hostname "" -}}
{{- end -}}

{{/*
Build PROXY_DOMAIN for env var (hostname with port if non-standard).
Usage:
{{ include "daytona.proxyDomain" . }}
*/}}
{{- define "daytona.proxyDomain" -}}
{{- $hostname := include "daytona.proxyUrl.hostname" . -}}
{{- $port := include "daytona.proxyUrl.port" . -}}
{{- $protocol := include "daytona.proxyUrl.protocol" . -}}
{{- $shouldOmitPort := or (eq $protocol "https") (and (eq $protocol "http") (eq $port "80")) (eq $port "") -}}
{{- if $shouldOmitPort -}}
{{- $hostname -}}
{{- else -}}
{{- printf "%s:%s" $hostname $port -}}
{{- end -}}
{{- end -}}

{{/*
Get the full proxyUrl value.
Usage:
{{ include "daytona.proxyUrl" . }}
*/}}
{{- define "daytona.proxyUrl" -}}
{{- required "proxyUrl is required" .Values.proxyUrl -}}
{{- end -}}

{{/*
Snapshot Manager URL.
Usage:
{{ include "daytona.snapshotManagerUrl" . }}
*/}}
{{- define "daytona.snapshotManagerUrl" -}}
{{- .Values.snapshotManagerUrl | default "http://snapshots.daytona.local:5000" -}}
{{- end -}}

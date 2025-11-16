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
Build PROXY_DOMAIN with correct port handling.
- For HTTPS: Always omits port (HTTPS URLs typically don't include ports)
- For HTTP: Omits port for default port 80, includes port for non-default ports
- If PROXY_DOMAIN is manually set and already contains a port, it's used as-is.
Usage:
{{ include "daytona.proxyDomain" . }}
*/}}
{{- define "daytona.proxyDomain" -}}
{{- $proxyPort := (.Values.services.proxy.env.PROXY_PORT | default 80 | toString | int) -}}
{{- $proxyProtocol := .Values.services.proxy.env.PROXY_PROTOCOL | default "http" | toString | lower -}}
{{- $shouldOmitPort := or (eq $proxyProtocol "https") (and (eq $proxyProtocol "http") (eq $proxyPort 80)) -}}
{{- $baseDomain := "" -}}
{{- if .Values.services.proxy.env.PROXY_DOMAIN -}}
  {{- $baseDomain = .Values.services.proxy.env.PROXY_DOMAIN -}}
  {{- if contains ":" $baseDomain -}}
    {{- /* PROXY_DOMAIN already contains a port, use as-is */ -}}
    {{- $baseDomain -}}
  {{- else -}}
    {{- /* PROXY_DOMAIN set but no port, conditionally append */ -}}
    {{- if $shouldOmitPort -}}
      {{- $baseDomain -}}
    {{- else -}}
      {{- printf "%s:%d" $baseDomain $proxyPort -}}
    {{- end -}}
  {{- end -}}
{{- else -}}
  {{- /* Auto-generate proxy.{{baseDomain}} */ -}}
  {{- $baseDomain = printf "proxy.%s" .Values.baseDomain -}}
  {{- if $shouldOmitPort -}}
    {{- $baseDomain -}}
  {{- else -}}
    {{- printf "%s:%d" $baseDomain $proxyPort -}}
  {{- end -}}
{{- end -}}
{{- end -}}

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
{{- default (printf "%s-%s" (include "daytona.fullname" .) $service) $serviceConfig.serviceAccount.name }}
{{- else }}
{{- default "default" $serviceConfig.serviceAccount.name }}
{{- end }}
{{- else }}
{{- default "default" "" }}
{{- end }}
{{- end }}

{{/*
Create the namespace to use
*/}}
{{- define "daytona.namespace" -}}
{{- if .Values.global.namespace }}
{{- .Values.global.namespace }}
{{- else }}
{{- .Release.Namespace }}
{{- end }}
{{- end }}

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

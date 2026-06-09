{{/*
Returns an error message when a secret value is missing, left at a value that was shipped
with the chart, or shorter than a required minimum. Returns an empty string when the value
is acceptable. Inputs: .v (value), .sentinel (optional shipped default), .min (optional
minimum length), .label (values path shown to the operator).
*/}}
{{- define "daytona.checkSecret" -}}
{{- $v := .v | toString | trim -}}
{{- if eq $v "" -}}
{{- printf "%s is required but no value is set" .label -}}
{{- else if and .sentinel (eq $v (.sentinel | toString)) -}}
{{- printf "%s is set to a value shipped with the chart and must be changed" .label -}}
{{- else if and .min (lt (len $v) (.min | int)) -}}
{{- printf "%s must be at least %d characters" .label (.min | int) -}}
{{- end -}}
{{- end -}}

{{/*
Fail-closed validation of security-sensitive secrets. Aborts `helm install/upgrade/template`
when a required secret is empty or still set to a value that was previously shipped as a
default. Skipped entirely when security.validateSecrets is false (for setups that inject all
secrets out-of-band via existingSecret / CSI / extraEnv).
*/}}
{{- define "daytona.validateSecrets" -}}
{{- if .Values.security.validateSecrets -}}
{{- $e := list -}}
{{- $api := .Values.services.api.env -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" $api.ENCRYPTION_KEY "sentinel" "CHANGE_ME_32_CHARACTER_SECRET_K!" "min" 32 "label" "services.api.env.ENCRYPTION_KEY")) -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" $api.ENCRYPTION_SALT "sentinel" "CHANGE_ME_RANDOM_SALT_VALUE" "label" "services.api.env.ENCRYPTION_SALT")) -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" $api.RUNNER_MANAGER_API_KEY "sentinel" "runner_manager_secret_key" "label" "services.api.env.RUNNER_MANAGER_API_KEY")) -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.proxy.env.PROXY_API_KEY "sentinel" "super_secret_key" "label" "services.proxy.env.PROXY_API_KEY")) -}}
{{- if .Values.services.sshGateway.enabled -}}
{{- /* When existingSecret is set, the operator's Secret supplies the keys and API_KEY,
       so none of these are required in values. */ -}}
{{- if not .Values.services.sshGateway.sshKeys.existingSecret -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.sshGateway.apiKey "sentinel" "supersecretapikey" "label" "services.sshGateway.apiKey (or set sshKeys.existingSecret)")) -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.sshGateway.sshKeys.privClientSSHKey "label" "services.sshGateway.sshKeys.privClientSSHKey (or set sshKeys.existingSecret)")) -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.sshGateway.sshKeys.pubClientSSHKey "label" "services.sshGateway.sshKeys.pubClientSSHKey (or set sshKeys.existingSecret)")) -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.sshGateway.sshKeys.privGatewaySSHKey "label" "services.sshGateway.sshKeys.privGatewaySSHKey (or set sshKeys.existingSecret)")) -}}
{{- end -}}
{{- end -}}
{{- if .Values.services.runnermanager.enabled -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.runnermanager.env.API_TOKEN "sentinel" "runner_manager_secret_key" "label" "services.runnermanager.env.API_TOKEN")) -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.runnermanager.env.SYSTEM_API_TOKEN "sentinel" "system_api_token" "label" "services.runnermanager.env.SYSTEM_API_TOKEN")) -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.runnermanager.env.API_KEY "sentinel" "secret_api_key" "label" "services.runnermanager.env.API_KEY")) -}}
{{- end -}}
{{- if .Values.services.runner.enabled -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.runner.env.API_TOKEN "sentinel" "secret_api_token" "label" "services.runner.env.API_TOKEN")) -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" .Values.services.runner.env.SYSTEM_API_TOKEN "sentinel" "system_api_token" "label" "services.runner.env.SYSTEM_API_TOKEN")) -}}
{{- end -}}
{{- if .Values.dex.enabled -}}
{{- range $i, $p := .Values.dex.config.staticPasswords -}}
{{- $e = append $e (include "daytona.checkSecret" (dict "v" $p.password "sentinel" "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W" "label" (printf "dex.config.staticPasswords[%d].password (bcrypt hash)" $i))) -}}
{{- end -}}
{{- end -}}
{{- /* Paired secrets must match across components */ -}}
{{- $rmkApi := $api.RUNNER_MANAGER_API_KEY | toString -}}
{{- $rmkRm := .Values.services.runnermanager.env.API_TOKEN | toString -}}
{{- if and .Values.services.runnermanager.enabled (ne $rmkApi "") (ne $rmkRm "") (ne $rmkApi $rmkRm) -}}
{{- $e = append $e "services.api.env.RUNNER_MANAGER_API_KEY must equal services.runnermanager.env.API_TOKEN" -}}
{{- end -}}
{{- $satRm := .Values.services.runnermanager.env.SYSTEM_API_TOKEN | toString -}}
{{- $satRun := .Values.services.runner.env.SYSTEM_API_TOKEN | toString -}}
{{- if and .Values.services.runnermanager.enabled .Values.services.runner.enabled (ne $satRm "") (ne $satRun "") (ne $satRm $satRun) -}}
{{- $e = append $e "services.runnermanager.env.SYSTEM_API_TOKEN must equal services.runner.env.SYSTEM_API_TOKEN" -}}
{{- end -}}
{{- $e = compact $e -}}
{{- if gt (len $e) 0 -}}
{{- fail (printf "\n\n[daytona] Refusing to render the chart - insecure or missing secret values:\n  - %s\n\nProvide unique values in your values file (see the chart README, \"Required secrets\"),\nor set security.validateSecrets=false if every secret is delivered out-of-band\n(existingSecret / Secrets Store CSI Driver / extraEnv secretKeyRef).\n" (join "\n  - " $e)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

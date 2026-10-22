{{/*
Proxy preview-authentication settings, kept in one place: the environment
variable names below are the only spelling of them in the chart templates.

The proxy itself enforces every preview credential check; none of these
settings turns authentication off.
*/}}

{{/*
Fail the render unless a value is a real boolean. `--set x=false` parses as a
boolean; a quoted "false" (or `--set-string`) is a string and is rejected, so
a typo can never flip a security setting.
Usage: {{ include "daytona.proxy.requireBool" (list "services.proxy.previewAuth.login.enabled" $value) }}
*/}}
{{- define "daytona.proxy.requireBool" -}}
{{- $path := index . 0 -}}
{{- $value := index . 1 -}}
{{- if kindIs "invalid" $value -}}
{{- fail (printf "%s is not set. Upgrading with --reuse-values keeps the previous chart's defaults; pass your values file with -f instead" $path) -}}
{{- else if not (kindIs "bool" $value) -}}
{{- fail (printf "%s must be true or false (unquoted), got %s %q" $path (kindOf $value) (toString $value)) -}}
{{- end -}}
{{- end -}}

{{/*
Environment variables that only the chart sets. services.proxy.extraEnv must
not set them: they carry the proxy's credential, its preview-authentication
mode, or the cookie scope, and each has a dedicated value.
*/}}
{{- define "daytona.proxy.reservedEnv" -}}
PROXY_API_KEY SIGNED_PREVIEW_TOKEN_RECHECK_ENABLED TOOLBOX_ONLY_MODE COOKIE_DOMAIN OIDC_CLIENT_SECRET
{{- end -}}

{{/*
Preview-authentication env entries for the proxy container.

- PREVIEW_LOGIN_ENABLED: the browser sign-in redirect for private previews.
  Off, a browser without a credential gets a 401 like any other client. Proxy
  images that predate the setting ignore it and keep the redirect.
- PREVIEW_AUTH_DISABLED: always "false". The proxy never honours it as a way
  to turn authentication off; rendering it pins the value so nothing else in
  the pod environment (envFrom, extraEnv) can set it.
- SIGNED_PREVIEW_TOKEN_RECHECK_ENABLED: re-validate signed preview links on
  open WebSockets, so a connection closes once its link expires.
- PREVIEW_WARNING_ENABLED: the interstitial warning page for browsers.
*/}}
{{- define "daytona.proxy.previewAuthEnv" -}}
{{- $proxy := .Values.services.proxy -}}
{{- $login := (($proxy.previewAuth).login).enabled -}}
{{- $recheck := ($proxy.previewAuth).signedLinkRecheck -}}
{{- $warning := ($proxy.previewWarning).enabled -}}
{{- include "daytona.proxy.requireBool" (list "services.proxy.previewAuth.login.enabled" $login) -}}
{{- include "daytona.proxy.requireBool" (list "services.proxy.previewAuth.signedLinkRecheck" $recheck) -}}
{{- include "daytona.proxy.requireBool" (list "services.proxy.previewWarning.enabled" $warning) }}
- name: PREVIEW_LOGIN_ENABLED
  value: {{ $login | toString | quote }}
- name: PREVIEW_AUTH_DISABLED
  value: "false"
- name: SIGNED_PREVIEW_TOKEN_RECHECK_ENABLED
  value: {{ $recheck | toString | quote }}
- name: PREVIEW_WARNING_ENABLED
  value: {{ $warning | toString | quote }}
{{- end -}}

{{/*
services.proxy.extraEnv, rendered after the chart's own entries; a non-string
value is quoted. Fails the render on an entry without a name, or one that sets a
reserved variable or any PREVIEW_* variable.
*/}}
{{- define "daytona.proxy.extraEnv" -}}
{{- $reserved := splitList " " (include "daytona.proxy.reservedEnv" .) -}}
{{- range $i, $e := .Values.services.proxy.extraEnv }}
{{- if not (and (kindIs "map" $e) $e.name) -}}
{{- fail (printf "services.proxy.extraEnv[%d] must be a map with a name" $i) -}}
{{- end -}}
{{- if or (has $e.name $reserved) (hasPrefix "PREVIEW_" $e.name) -}}
{{- fail (printf "services.proxy.extraEnv[%d]: %s is set by the chart and cannot be overridden; see \"Preview authentication\" in the chart README" $i $e.name) -}}
{{- end }}
{{- if hasKey $e "value" }}
{{- $e = merge (dict "value" (toString $e.value)) $e }}
{{- end }}
- {{ toYaml $e | nindent 2 | trim }}
{{- end -}}
{{- end -}}

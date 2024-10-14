{{/*
Create a default fully qualified postgresql name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "watkins.postgresql.fullname" -}}
{{- include "common.names.dependency.fullname" (dict "chartName" "postgresql" "chartValues" .Values.postgresql "context" $) -}}
{{- end -}}

{{/*
Create a default fully qualified keycloak name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "watkins.keycloak.fullname" -}}
{{- include "common.names.dependency.fullname" (dict "chartName" "keycloak" "chartValues" .Values.keycloak "context" $) -}}
{{- end -}}

{{/*
Create a default fully qualified rabbitmq name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "watkins.rabbitmq.fullname" -}}
{{- include "common.names.dependency.fullname" (dict "chartName" "rabbitmq" "chartValues" .Values.rabbitmq "context" $) -}}
{{- end -}}

{{/*
Create a default fully qualified redis name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "watkins.redis.fullname" -}}
{{- include "common.names.dependency.fullname" (dict "chartName" "redis" "chartValues" .Values.redis "context" $) -}}
{{- end -}}

{{/*
Return Watkins hostname
*/}}
{{- define "watkins.hostname" -}}
{{- .Values.ingress.hostname -}}
{{- end -}}

{{/*
Return Watkins url
*/}}
{{- define "watkins.url" -}}
{{- printf "%s://%s" (ternary "https" "http" .Values.ingress.tls) (include "watkins.hostname" .) -}}
{{- end -}}

{{/*
Return Watkins admin dashboard url
*/}}
{{- define "watkins.adminDashboard.url" -}}
{{- printf "%s://admin.%s" (ternary "https" "http" .Values.ingress.tls) (include "watkins.hostname" .) -}}
{{- end -}}

{{/*
Return Watkins docs url
*/}}
{{- define "watkins.docs.url" -}}
{{- printf "%s://docs.%s" (ternary "https" "http" .Values.ingress.tls) (include "watkins.hostname" .) -}}
{{- end -}}

{{/*
Return Watkins API url
*/}}
{{- define "watkins.api.url" -}}
{{- printf "%s://api.%s" (ternary "https" "http" .Values.ingress.tls) (include "watkins.hostname" .) -}}
{{- end -}}

{{/*
Return Watkins internal API url
*/}}
{{- define "watkins.api.internalUrl" -}}
{{- printf "http://%s.%s" (include "watkins.api.fullname" .) .Release.Namespace -}}
{{- end -}}

{{/*
Return Watkins notification url
*/}}
{{- define "watkins.notification.url" -}}
{{- printf "%s://notification.%s" (ternary "https" "http" .Values.ingress.tls) (include "watkins.hostname" .) -}}
{{- end -}}

{{/*
Return Keycloak hostname
*/}}
{{- define "watkins.keycloak.hostname" -}}
{{- printf "id.%s" (include "watkins.hostname" .) -}}
{{- end -}}

{{/*
Return Keycloak issuer
*/}}
{{- define "watkins.keycloak.issuer" -}}
{{- if .Values.keycloak.enabled -}}
    {{- printf "%s/realms/%s" (include "watkins.keycloak.baseUrl" .) .Values.keycloakConfig.realm -}}
{{- else -}}
    {{- printf "%s/realms/%s" .Values.externalKeycloak.url .Values.keycloakConfig.realm -}}
{{- end -}}
{{- end -}}

{{/*
Return Keycloak url
*/}}
{{- define "watkins.keycloak.url" -}}
{{- if .Values.keycloak.enabled -}}
    {{- printf "http://%s/realms/%s" (include "watkins.keycloak.fullname" .) .Values.keycloakConfig.realm -}}
{{- else -}}
    {{- printf "%s/realms/%s" .Values.externalKeycloak.url .Values.keycloakConfig.realm -}}
{{- end -}}
{{- end -}}

{{/*
Return Keycloak admin url
*/}}
{{- define "watkins.keycloak.adminUrl" -}}
{{- if .Values.keycloak.enabled -}}
    {{- printf "http://%s/admin/realms/%s" (include "watkins.keycloak.fullname" .) .Values.keycloakConfig.realm -}}
{{- else -}}
    {{- printf "%s/admin/realms/%s" .Values.externalKeycloak.url .Values.keycloakConfig.realm -}}
{{- end -}}
{{- end -}}

{{/*
Return Keycloak base url
*/}}
{{- define "watkins.keycloak.baseUrl" -}}
{{- if .Values.keycloak.enabled -}}
    {{- printf "%s://%s" (ternary "https" "http" .Values.ingress.tls) (include "watkins.keycloak.hostname" .) -}}
{{- else -}}
    {{- printf "%s" .Values.externalKeycloak.url -}}
{{- end -}}
{{- end -}}

{{/*
Return api fullname
*/}}
{{- define "watkins.api.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "api" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return db-migration fullname
*/}}
{{- define "watkins.db-migration.fullname" -}}
{{- printf "%s-%s-%s-%s" (include "common.names.fullname" .) "db-migration" (.Values.image.tag | default .Chart.AppVersion | replace "." "-") (randAlphaNum 5 | lower ) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return email fullname
*/}}
{{- define "watkins.email.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "email" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return admin dashboard fullname
*/}}
{{- define "watkins.adminDashboard.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "admin-dashboard" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return dashboard fullname
*/}}
{{- define "watkins.dashboard.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "dashboard" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return docs fullname
*/}}
{{- define "watkins.docs.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "docs" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return domain notification publisher fullname
*/}}
{{- define "watkins.domainNotificationPublisher.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "domain-notification-publisher" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return workspace watcher fullname
*/}}
{{- define "watkins.workspaceWatcher.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "workspace-watcher" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return realtime server fullname
*/}}
{{- define "watkins.realtimeServer.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "realtime-server" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return workspace provisioner fullname
*/}}
{{- define "watkins.workspaceProvisioner.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "workspace-provisioner" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return workspace instance service account fullname
*/}}
{{- define "watkins.workspaceInstance.serviceAccountName" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "workspace-instance-service-account" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return workspace proxy fullname
*/}}
{{- define "watkins.workspaceProxy.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "workspace-proxy" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return workspace usage fullname
*/}}
{{- define "watkins.workspaceUsage.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "workspace-usage" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return workspace ssh gateway fullname
*/}}
{{- define "watkins.sshGateway.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "ssh-gateway" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return keycloak init fullname
*/}}
{{- define "watkins.keycloakInit.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "keycloak-init" | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{/*
Return workspace volume init fullname
*/}}
{{- define "watkins.workspaceVolumeInit.fullname" -}}
{{- printf "%s-%s" (include "common.names.fullname" .) "workspace-volume-init" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Return the proper Container Image Registry Secret Names
*/}}
{{- define "watkins.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image ) "global" .Values.global) -}}
{{- end -}}

{{/*
Return workspace volume storage class
*/}}
{{- define "watkins.workspace.storageClass" -}}
{{- if .Values.components.workspaceVolumeInit.enabled -}}
    {{- printf "workspace-preload-%s" (regexReplaceAll "\\W+" (or .Values.image.tag .Chart.AppVersion) "-" | lower) -}}
{{- else -}}
    {{- printf "%s" .Values.configuration.workspaceStorageClass -}}
{{- end -}}
{{- end -}}

{{/*
Return workspace namespace
*/}}
{{- define "watkins.workspaceNamespace" -}}
{{- if .Values.configuration.workspaceNamespace.create -}}
{{- or .Values.configuration.workspaceNamespace.name (printf "%s-workspace" .Release.Name) -}}
{{- else }}
{{- or .Values.configuration.workspaceNamespace.name .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{/*
Return Watkins image
*/}}
{{- define "watkins.image" -}}
{{- $registryName := .imageRoot.registry -}}
{{- $repositoryName := printf "%s/%s" .imageRoot.repository .component -}}
{{- $separator := ":" -}}
{{- $termination := (or .imageRoot.tag .appVersion) | toString -}}
{{- if .global }}
    {{- if .global.imageRegistry }}
     {{- $registryName = .global.imageRegistry -}}
    {{- end -}}
{{- end -}}
{{- if .imageRoot.digest }}
    {{- $separator = "@" -}}
    {{- $termination = .imageRoot.digest | toString -}}
{{- end -}}
{{- if $registryName }}
    {{- printf "%s/%s%s%s" $registryName $repositoryName $separator $termination -}}
{{- else -}}
    {{- printf "%s%s%s"  $repositoryName $separator $termination -}}
{{- end -}}
{{- end -}}

{{/*
Return api image
*/}}
{{- define "watkins.api.image" -}}
{{- $component := "api" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return db-migration image
*/}}
{{- define "watkins.db-migration.image" -}}
{{- $component := "migration" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return admin dashboard image
*/}}
{{- define "watkins.adminDashboard.image" -}}
{{- $component := "admin-dashboard" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return dashboard image
*/}}
{{- define "watkins.dashboard.image" -}}
{{- $component := "dashboard" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return docs image
*/}}
{{- define "watkins.docs.image" -}}
{{- $component := "docs" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return domain notification publisher image
*/}}
{{- define "watkins.domainNotificationPublisher.image" -}}
{{- $component := "domain-notification-publisher" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return watcher image
*/}}
{{- define "watkins.workspaceWatcher.image" -}}
{{- $component := "workspace-watcher" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return realtime server image
*/}}
{{- define "watkins.realtimeServer.image" -}}
{{- $component := "realtime-server" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return workspace provisioner image
*/}}
{{- define "watkins.workspaceProvisioner.image" -}}
{{- $component := "workspace-provisioner" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return workspace proxy image
*/}}
{{- define "watkins.workspaceProxy.image" -}}
{{- $component := "workspace-proxy" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return workspace usage image
*/}}
{{- define "watkins.workspaceUsage.image" -}}
{{- $component := "workspace-usage" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return workspace ssh gateway image
*/}}
{{- define "watkins.sshGateway.image" -}}
{{- $component := "ssh-gateway" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return keycloak init image
*/}}
{{- define "watkins.keycloakInit.image" -}}
{{- $component := "keycloak-init" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}


{{/*
Return workspace volume init image
*/}}
{{- define "watkins.workspaceVolumeInit.image" -}}
{{- $component := "workspace-volume-init-job" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return workspace image
*/}}
{{- define "watkins.workspace.image" -}}
  {{- if .Values.components.workspaceProvisioner.workspaces.defaultWorkspaceContainerImage }}
    {{- .Values.components.workspaceProvisioner.workspaces.defaultWorkspaceContainerImage -}}
  {{- else -}}
    {{- $component := "workspace-image" -}}
    {{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
  {{- end -}}
{{- end -}}

{{/*
Return branding image
*/}}
{{- define "watkins.branding.image" -}}
{{- $component := "branding" -}}
{{- if eq .Values.components.branding.image "" }}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- else -}}
{{ .Values.components.branding.image }}
{{- end -}}
{{- end -}}

{{/*
Return supervisor sshd extension image
*/}}
{{- define "watkins.supervisorSshd.image" -}}
{{- $component := "supervisor-sshd" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return supervisor theia extension image
*/}}
{{- define "watkins.supervisorTheia.image" -}}
{{- $component := "supervisor-theia" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return supervisor openvscode-server extension image
*/}}
{{- define "watkins.supervisorOpenVSCodeServer.image" -}}
{{- $component := "supervisor-openvscode-server" -}}
{{- include "watkins.image" (dict "imageRoot" .Values.image "global" .Values.global "appVersion" .Chart.AppVersion "component" $component) -}}
{{- end -}}

{{/*
Return the Database hostname
*/}}
{{- define "watkins.database.host" }}
{{- if eq .Values.postgresql.architecture "replication" }}
{{- ternary (include "watkins.postgresql.fullname" .) .Values.externalDatabase.host .Values.postgresql.enabled -}}-primary
{{- else -}}
{{- ternary (include "watkins.postgresql.fullname" .) .Values.externalDatabase.host .Values.postgresql.enabled -}}
{{- end -}}
{{- end -}}

{{/*
Return the Database port
*/}}
{{- define "watkins.database.port" -}}
{{- ternary 5432 .Values.externalDatabase.port .Values.postgresql.enabled -}}
{{- end -}}

{{/*
Return the Database database name
*/}}
{{- define "watkins.database.name" -}}
{{- if .Values.postgresql.enabled }}
    {{- .Values.postgresql.auth.database -}}
{{- else -}}
    {{- .Values.externalDatabase.database -}}
{{- end -}}
{{- end -}}

{{/*
Return the Database user
*/}}
{{- define "watkins.database.user" -}}
{{- if .Values.postgresql.enabled -}}
    {{- .Values.postgresql.auth.username -}}
{{- else -}}
    {{- .Values.externalDatabase.user -}}
{{- end -}}
{{- end -}}

{{/*
Return the Database password secret
*/}}
{{- define "watkins.database.secretName" -}}
{{- if .Values.postgresql.enabled -}}
    {{- default (include "watkins.postgresql.fullname" .) (tpl .Values.postgresql.auth.existingSecret $) -}}
{{- else -}}
    {{- default (printf "%s-externaldb" .Release.Name) (tpl .Values.externalDatabase.existingSecret $) -}}
{{- end -}}
{{- end -}}

{{/*
Return the Database password secret key
*/}}
{{- define "watkins.database.secretKey" -}}
{{- if .Values.postgresql.enabled -}}
    {{- print "password" -}}
{{- else -}}
    {{- if .Values.externalDatabase.existingSecret -}}
        {{- if .Values.externalDatabase.existingSecretPasswordKey -}}
            {{- printf "%s" .Values.externalDatabase.existingSecretPasswordKey -}}
        {{- else -}}
            {{- print "db-password" -}}
        {{- end -}}
    {{- else -}}
        {{- print "db-password" -}}
    {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return the RabbitMQ host
*/}}
{{- define "watkins.rabbitmq.host" -}}
{{- if .Values.rabbitmq.enabled }}
    {{- printf "%s" (include "watkins.rabbitmq.fullname" .) -}}
{{- else -}}
    {{- printf "%s" .Values.externalRabbitmq.host -}}
{{- end -}}
{{- end -}}

{{/*
Return the RabbitMQ Port
*/}}
{{- define "watkins.rabbitmq.port" -}}
{{- if .Values.rabbitmq.enabled }}
    {{- printf "%d" (.Values.rabbitmq.service.ports.amqp | int ) -}}
{{- else -}}
    {{- printf "%d" (.Values.externalRabbitmq.port | int ) -}}
{{- end -}}
{{- end -}}

{{/*
Return the RabbitMQ username
*/}}
{{- define "watkins.rabbitmq.user" -}}
{{- if .Values.rabbitmq.enabled }}
    {{- printf "%s" .Values.rabbitmq.auth.username -}}
{{- else -}}
    {{- printf "%s" .Values.externalRabbitmq.username -}}
{{- end -}}
{{- end -}}

{{/*
Return the RabbitMQ secret name
*/}}
{{- define "watkins.rabbitmq.secretName" -}}
{{- if .Values.externalRabbitmq.existingPasswordSecret -}}
    {{- printf "%s" .Values.externalRabbitmq.existingPasswordSecret -}}
{{- else if .Values.rabbitmq.enabled -}}
    {{- printf "%s" (include "watkins.rabbitmq.fullname" .) -}}
{{- else -}}
    {{- printf "%s-%s" (include "common.names.fullname" .) "externalrabbitmq" -}}
{{- end -}}
{{- end -}}

{{/*
Return the RabbitMQ secret key
*/}}
{{- define "watkins.rabbitmq.secretKey" -}}
{{- if .Values.rabbitmq.enabled -}}
    {{- print "rabbitmq-password" -}}
{{- else -}}
    {{- if .Values.externalRabbitmq.existingSecret -}}
        {{- if .Values.externalRabbitmq.existingSecretPasswordKey -}}
            {{- printf "%s" .Values.externalRabbitmq.existingSecretPasswordKey -}}
        {{- else -}}
            {{- print "rabbitmq-password" -}}
        {{- end -}}
    {{- else -}}
        {{- print "rabbitmq-password" -}}
    {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Return Redis(TM) host
*/}}
{{- define "watkins.redis.host" -}}
{{- if .Values.redis.enabled -}}
    {{- printf "%s-master" (include "watkins.redis.fullname" .) -}}
{{- else -}}
    {{- print .Values.externalRedis.host -}}
{{- end -}}
{{- end -}}

{{/*
Return Redis(TM) port
*/}}
{{- define "watkins.redis.port" -}}
{{- if .Values.redis.enabled -}}
    {{- print .Values.redis.master.service.ports.redis -}}
{{- else -}}
    {{- print .Values.externalRedis.port  -}}
{{- end -}}
{{- end -}}

{{/*
Return the Redis Secret Name
*/}}
{{- define "watkins.redis.secretName" -}}
{{- if .Values.redis.enabled -}}
    {{- printf "%s" (include "watkins.redis.fullname" .) -}}
{{- else if .Values.externalDatabase.existingSecret -}}
    {{- printf "%s" .Values.externalDatabase.existingSecret -}}
{{- else -}}
    {{- printf "%s-externalredis" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Retrieve key of the Redis secret
*/}}
{{- define "watkins.redis.secretKey" -}}
{{- if .Values.redis.enabled -}}
    {{- print "redis-password" -}}
{{- else -}}
    {{- if .Values.externalRedis.existingSecret -}}
        {{- if .Values.externalRedis.existingSecretPasswordKey -}}
            {{- printf "%s" .Values.externalRedis.existingSecretPasswordKey -}}
        {{- else -}}
            {{- print "redis-password" -}}
        {{- end -}}
    {{- else -}}
        {{- print "redis-password" -}}
    {{- end -}}
{{- end -}}
{{- end -}}

# {{ .Values.components.workspaceVolumeInit.pullImages.images | quote }}
{{/*
Return list of dockerimages to pull in volume init
*/}}
{{- define "watkins.workspace.preloadImages" -}}
  {{- if .Values.components.workspaceVolumeInit.enabled -}}
    {{- if .Values.components.workspaceVolumeInit.pullImages.images }}
      {{- printf "%s,%s" .Values.components.workspaceProvisioner.workspaces.defaultContainerImage .Values.components.workspaceVolumeInit.pullImages.images -}}
    {{- else -}}
      {{- print .Values.components.workspaceProvisioner.workspaces.defaultContainerImage -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

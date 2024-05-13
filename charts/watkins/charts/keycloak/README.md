# keycloak

![Version: 17.3.1](https://img.shields.io/badge/Version-17.3.1-informational?style=flat-square) ![AppVersion: 22.0.5](https://img.shields.io/badge/AppVersion-22.0.5-informational?style=flat-square)

Keycloak is a high performance Java-based identity and access management solution. It lets developers add an authentication layer to their applications with minimum effort.

**Homepage:** <https://bitnami.com>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| VMware, Inc. |  | <https://github.com/bitnami/charts> |

## Source Code

* <https://github.com/bitnami/charts/tree/main/bitnami/keycloak>

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| oci://registry-1.docker.io/bitnamicharts | common | 2.x.x |
| oci://registry-1.docker.io/bitnamicharts | postgresql | 13.x.x |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| args | list | `[]` |  |
| auth.adminPassword | string | `""` |  |
| auth.adminUser | string | `"user"` |  |
| auth.annotations | object | `{}` |  |
| auth.existingSecret | string | `""` |  |
| auth.passwordSecretKey | string | `""` |  |
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `11` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPU | string | `""` |  |
| autoscaling.targetMemory | string | `""` |  |
| cache.enabled | bool | `true` |  |
| cache.stackFile | string | `""` |  |
| cache.stackName | string | `"kubernetes"` |  |
| clusterDomain | string | `"cluster.local"` |  |
| command | list | `[]` |  |
| commonAnnotations | object | `{}` |  |
| commonLabels | object | `{}` |  |
| configuration | string | `""` |  |
| containerPorts.http | int | `8080` |  |
| containerPorts.https | int | `8443` |  |
| containerPorts.infinispan | int | `7800` |  |
| containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| containerSecurityContext.enabled | bool | `true` |  |
| containerSecurityContext.privileged | bool | `false` |  |
| containerSecurityContext.readOnlyRootFilesystem | bool | `false` |  |
| containerSecurityContext.runAsNonRoot | bool | `true` |  |
| containerSecurityContext.runAsUser | int | `1001` |  |
| containerSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| customLivenessProbe | object | `{}` |  |
| customReadinessProbe | object | `{}` |  |
| customStartupProbe | object | `{}` |  |
| diagnosticMode.args[0] | string | `"infinity"` |  |
| diagnosticMode.command[0] | string | `"sleep"` |  |
| diagnosticMode.enabled | bool | `false` |  |
| dnsConfig | object | `{}` |  |
| dnsPolicy | string | `""` |  |
| enableServiceLinks | bool | `true` |  |
| existingConfigmap | string | `""` |  |
| externalDatabase.annotations | object | `{}` |  |
| externalDatabase.database | string | `"bitnami_keycloak"` |  |
| externalDatabase.existingSecret | string | `""` |  |
| externalDatabase.existingSecretDatabaseKey | string | `""` |  |
| externalDatabase.existingSecretHostKey | string | `""` |  |
| externalDatabase.existingSecretPasswordKey | string | `""` |  |
| externalDatabase.existingSecretPortKey | string | `""` |  |
| externalDatabase.existingSecretUserKey | string | `""` |  |
| externalDatabase.host | string | `""` |  |
| externalDatabase.password | string | `""` |  |
| externalDatabase.port | int | `5432` |  |
| externalDatabase.user | string | `"bn_keycloak"` |  |
| extraContainerPorts | list | `[]` |  |
| extraDeploy | list | `[]` |  |
| extraEnvVars | list | `[]` |  |
| extraEnvVarsCM | string | `""` |  |
| extraEnvVarsSecret | string | `""` |  |
| extraStartupArgs | string | `""` |  |
| extraVolumeMounts | list | `[]` |  |
| extraVolumes | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| global.imagePullSecrets | list | `[]` |  |
| global.imageRegistry | string | `""` |  |
| global.storageClass | string | `""` |  |
| hostAliases | list | `[]` |  |
| httpRelativePath | string | `"/"` |  |
| image.debug | bool | `false` |  |
| image.digest | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.pullSecrets | list | `[]` |  |
| image.registry | string | `"docker.io"` |  |
| image.repository | string | `"bitnami/keycloak"` |  |
| image.tag | string | `"22.0.5-debian-11-r0"` |  |
| ingress.annotations | object | `{}` |  |
| ingress.apiVersion | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.extraHosts | list | `[]` |  |
| ingress.extraPaths | list | `[]` |  |
| ingress.extraRules | list | `[]` |  |
| ingress.extraTls | list | `[]` |  |
| ingress.hostname | string | `"keycloak.local"` |  |
| ingress.ingressClassName | string | `""` |  |
| ingress.labels | object | `{}` |  |
| ingress.path | string | `"{{ .Values.httpRelativePath }}"` |  |
| ingress.pathType | string | `"ImplementationSpecific"` |  |
| ingress.secrets | list | `[]` |  |
| ingress.selfSigned | bool | `false` |  |
| ingress.servicePort | string | `"http"` |  |
| ingress.tls | bool | `false` |  |
| initContainers | list | `[]` |  |
| initdbScripts | object | `{}` |  |
| initdbScriptsConfigMap | string | `""` |  |
| keycloakConfigCli.annotations."helm.sh/hook" | string | `"post-install,post-upgrade,post-rollback"` |  |
| keycloakConfigCli.annotations."helm.sh/hook-delete-policy" | string | `"hook-succeeded,before-hook-creation"` |  |
| keycloakConfigCli.annotations."helm.sh/hook-weight" | string | `"5"` |  |
| keycloakConfigCli.args | list | `[]` |  |
| keycloakConfigCli.backoffLimit | int | `1` |  |
| keycloakConfigCli.cleanupAfterFinished.enabled | bool | `false` |  |
| keycloakConfigCli.cleanupAfterFinished.seconds | int | `600` |  |
| keycloakConfigCli.command | list | `[]` |  |
| keycloakConfigCli.configuration | object | `{}` |  |
| keycloakConfigCli.containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| keycloakConfigCli.containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| keycloakConfigCli.containerSecurityContext.enabled | bool | `true` |  |
| keycloakConfigCli.containerSecurityContext.privileged | bool | `false` |  |
| keycloakConfigCli.containerSecurityContext.readOnlyRootFilesystem | bool | `false` |  |
| keycloakConfigCli.containerSecurityContext.runAsNonRoot | bool | `true` |  |
| keycloakConfigCli.containerSecurityContext.runAsUser | int | `1001` |  |
| keycloakConfigCli.containerSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| keycloakConfigCli.enabled | bool | `false` |  |
| keycloakConfigCli.existingConfigmap | string | `""` |  |
| keycloakConfigCli.extraEnvVars | list | `[]` |  |
| keycloakConfigCli.extraEnvVarsCM | string | `""` |  |
| keycloakConfigCli.extraEnvVarsSecret | string | `""` |  |
| keycloakConfigCli.extraVolumeMounts | list | `[]` |  |
| keycloakConfigCli.extraVolumes | list | `[]` |  |
| keycloakConfigCli.hostAliases | list | `[]` |  |
| keycloakConfigCli.image.digest | string | `""` |  |
| keycloakConfigCli.image.pullPolicy | string | `"IfNotPresent"` |  |
| keycloakConfigCli.image.pullSecrets | list | `[]` |  |
| keycloakConfigCli.image.registry | string | `"docker.io"` |  |
| keycloakConfigCli.image.repository | string | `"bitnami/keycloak-config-cli"` |  |
| keycloakConfigCli.image.tag | string | `"5.9.0-debian-11-r0"` |  |
| keycloakConfigCli.initContainers | list | `[]` |  |
| keycloakConfigCli.nodeSelector | object | `{}` |  |
| keycloakConfigCli.podAnnotations | object | `{}` |  |
| keycloakConfigCli.podLabels | object | `{}` |  |
| keycloakConfigCli.podSecurityContext.enabled | bool | `true` |  |
| keycloakConfigCli.podSecurityContext.fsGroup | int | `1001` |  |
| keycloakConfigCli.podTolerations | list | `[]` |  |
| keycloakConfigCli.resources.limits | object | `{}` |  |
| keycloakConfigCli.resources.requests | object | `{}` |  |
| keycloakConfigCli.sidecars | list | `[]` |  |
| kubeVersion | string | `""` |  |
| lifecycleHooks | object | `{}` |  |
| livenessProbe.enabled | bool | `true` |  |
| livenessProbe.failureThreshold | int | `3` |  |
| livenessProbe.initialDelaySeconds | int | `300` |  |
| livenessProbe.periodSeconds | int | `1` |  |
| livenessProbe.successThreshold | int | `1` |  |
| livenessProbe.timeoutSeconds | int | `5` |  |
| logging.level | string | `"INFO"` |  |
| logging.output | string | `"default"` |  |
| metrics.enabled | bool | `false` |  |
| metrics.prometheusRule.enabled | bool | `false` |  |
| metrics.prometheusRule.groups | list | `[]` |  |
| metrics.prometheusRule.labels | object | `{}` |  |
| metrics.prometheusRule.namespace | string | `""` |  |
| metrics.service.annotations."prometheus.io/port" | string | `"{{ .Values.metrics.service.ports.http }}"` |  |
| metrics.service.annotations."prometheus.io/scrape" | string | `"true"` |  |
| metrics.service.extraPorts | list | `[]` |  |
| metrics.service.ports.http | int | `8080` |  |
| metrics.serviceMonitor.enabled | bool | `false` |  |
| metrics.serviceMonitor.endpoints[0].path | string | `"{{ include \"keycloak.httpPath\" . }}metrics"` |  |
| metrics.serviceMonitor.endpoints[1].path | string | `"{{ include \"keycloak.httpPath\" . }}realms/master/metrics"` |  |
| metrics.serviceMonitor.honorLabels | bool | `false` |  |
| metrics.serviceMonitor.interval | string | `"30s"` |  |
| metrics.serviceMonitor.jobLabel | string | `""` |  |
| metrics.serviceMonitor.labels | object | `{}` |  |
| metrics.serviceMonitor.metricRelabelings | list | `[]` |  |
| metrics.serviceMonitor.namespace | string | `""` |  |
| metrics.serviceMonitor.path | string | `""` |  |
| metrics.serviceMonitor.port | string | `"http"` |  |
| metrics.serviceMonitor.relabelings | list | `[]` |  |
| metrics.serviceMonitor.scrapeTimeout | string | `""` |  |
| metrics.serviceMonitor.selector | object | `{}` |  |
| nameOverride | string | `""` |  |
| namespaceOverride | string | `""` |  |
| networkPolicy.additionalRules | object | `{}` |  |
| networkPolicy.allowExternal | bool | `true` |  |
| networkPolicy.enabled | bool | `false` |  |
| nodeAffinityPreset.key | string | `""` |  |
| nodeAffinityPreset.type | string | `""` |  |
| nodeAffinityPreset.values | list | `[]` |  |
| nodeSelector | object | `{}` |  |
| pdb.create | bool | `false` |  |
| pdb.maxUnavailable | string | `""` |  |
| pdb.minAvailable | int | `1` |  |
| podAffinityPreset | string | `""` |  |
| podAnnotations | object | `{}` |  |
| podAntiAffinityPreset | string | `"soft"` |  |
| podLabels | object | `{}` |  |
| podManagementPolicy | string | `"Parallel"` |  |
| podSecurityContext.enabled | bool | `true` |  |
| podSecurityContext.fsGroup | int | `1001` |  |
| postgresql.architecture | string | `"standalone"` |  |
| postgresql.auth.database | string | `"bitnami_keycloak"` |  |
| postgresql.auth.existingSecret | string | `""` |  |
| postgresql.auth.password | string | `""` |  |
| postgresql.auth.postgresPassword | string | `""` |  |
| postgresql.auth.username | string | `"bn_keycloak"` |  |
| postgresql.enabled | bool | `true` |  |
| priorityClassName | string | `""` |  |
| production | bool | `false` |  |
| proxy | string | `"passthrough"` |  |
| rbac.create | bool | `false` |  |
| rbac.rules | list | `[]` |  |
| readinessProbe.enabled | bool | `true` |  |
| readinessProbe.failureThreshold | int | `3` |  |
| readinessProbe.initialDelaySeconds | int | `30` |  |
| readinessProbe.periodSeconds | int | `10` |  |
| readinessProbe.successThreshold | int | `1` |  |
| readinessProbe.timeoutSeconds | int | `1` |  |
| replicaCount | int | `1` |  |
| resources.limits | object | `{}` |  |
| resources.requests | object | `{}` |  |
| schedulerName | string | `""` |  |
| service.annotations | object | `{}` |  |
| service.clusterIP | string | `""` |  |
| service.externalTrafficPolicy | string | `"Cluster"` |  |
| service.extraHeadlessPorts | list | `[]` |  |
| service.extraPorts | list | `[]` |  |
| service.headless.annotations | object | `{}` |  |
| service.headless.extraPorts | list | `[]` |  |
| service.http.enabled | bool | `true` |  |
| service.loadBalancerIP | string | `""` |  |
| service.loadBalancerSourceRanges | list | `[]` |  |
| service.nodePorts.http | string | `""` |  |
| service.nodePorts.https | string | `""` |  |
| service.ports.http | int | `80` |  |
| service.ports.https | int | `443` |  |
| service.sessionAffinity | string | `"None"` |  |
| service.sessionAffinityConfig | object | `{}` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automountServiceAccountToken | bool | `true` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.extraLabels | object | `{}` |  |
| serviceAccount.name | string | `""` |  |
| sidecars | list | `[]` |  |
| spi.existingSecret | string | `""` |  |
| spi.hostnameVerificationPolicy | string | `""` |  |
| spi.passwordsSecret | string | `""` |  |
| spi.truststoreFilename | string | `"keycloak-spi.truststore.jks"` |  |
| spi.truststorePassword | string | `""` |  |
| startupProbe.enabled | bool | `false` |  |
| startupProbe.failureThreshold | int | `60` |  |
| startupProbe.initialDelaySeconds | int | `30` |  |
| startupProbe.periodSeconds | int | `5` |  |
| startupProbe.successThreshold | int | `1` |  |
| startupProbe.timeoutSeconds | int | `1` |  |
| terminationGracePeriodSeconds | string | `""` |  |
| tls.autoGenerated | bool | `false` |  |
| tls.enabled | bool | `false` |  |
| tls.existingSecret | string | `""` |  |
| tls.keystoreFilename | string | `"keycloak.keystore.jks"` |  |
| tls.keystorePassword | string | `""` |  |
| tls.passwordsSecret | string | `""` |  |
| tls.truststoreFilename | string | `"keycloak.truststore.jks"` |  |
| tls.truststorePassword | string | `""` |  |
| tls.usePem | bool | `false` |  |
| tolerations | list | `[]` |  |
| topologySpreadConstraints | list | `[]` |  |
| updateStrategy.rollingUpdate | object | `{}` |  |
| updateStrategy.type | string | `"RollingUpdate"` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.13.1](https://github.com/norwoodj/helm-docs/releases/v1.13.1)

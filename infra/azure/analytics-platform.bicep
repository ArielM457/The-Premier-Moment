// Despliegue completo de la analítica (Persona 2) en Azure.
//
// Reutiliza main.bicep (Event Hubs y Storage de Persona 1) y analytics.bicep
// (match-insights y contenedores de la analítica) como módulos, y añade:
// Log Analytics, Azure Container Registry, una identidad administrada con sus
// roles, un entorno de Container Apps y, en la fase 2, las aplicaciones:
//   - api:    API de Persona 4 con la analítica real de Persona 2 (pública).
//   - web:    interfaz de Persona 4 servida por nginx (pública, opcional).
//   - worker: procesador continuo de match-events a match-insights.
//   - replay: trabajo manual que repite un partido de Supabase en match-events.
//
// Fase 1 (deployApps=false): infraestructura y registro, sin imágenes.
// Fase 2 (deployApps=true): las aplicaciones con las imágenes ya publicadas.
targetScope = 'resourceGroup'

@description('Prefijo corto, en minúsculas, para distinguir el despliegue.')
@minLength(3)
@maxLength(9)
param projectPrefix string

@description('Entorno lógico usado en nombres y etiquetas.')
@allowed([
  'dev'
  'test'
  'demo'
])
param environmentName string = 'demo'

@description('Región de los recursos. De forma predeterminada usa la región del grupo.')
param location string = resourceGroup().location

@description('Región del entorno de Container Apps y sus aplicaciones. La suscripción admite un solo entorno: debe estar donde haya GPU T4 para el estadio (eastus sí, eastus2 no).')
param environmentLocation string = location

@description('Declara el perfil GPU T4 que agregan los scripts de MESSI y Roboflow; sin él, un despliegue lo quitaría del entorno.')
param gpuWorkloadProfile bool = false

@description('false en la fase 1; true cuando las imágenes ya están en el registro.')
param deployApps bool = false

@description('Imagen del backend, por ejemplo <registro>.azurecr.io/match-intelligence-api:<etiqueta>.')
param apiImage string = ''

@description('Imagen de la interfaz. Vacía para no desplegarla.')
param webImage string = ''

@description('Cadena del Session pooler de Supabase. Vacía: la API usa los generadores sintéticos.')
@secure()
param supabaseDbUrl string = ''

@description('URL del proyecto de Supabase (https://<ref>.supabase.co). La API valida con ella las sesiones de los editores; vacía, la revisión editorial responde 503.')
param supabaseUrl string = ''

@description('Ruta del vídeo MESSI (…/match.mp4, con sus archivos compañeros) en el contenedor authorized-videos del Storage del despliegue. Vacía: la API muestra la cancha sintética.')
param visionVideoBlobName string = ''

@description('Roboflow Suite: detecciones sobre el vídeo MESSI. El estadio exige este modelo y TeamSpotting.')
param roboflowEndpoint string = ''

@secure()
param roboflowApiKey string = ''

@description('SoccerNet TeamSpotting: acciones del vídeo MESSI, analizado antes de Play.')
param teamspottingEndpoint string = ''

@secure()
param teamspottingApiKey string = ''

@description('1 mantiene la API encendida (sin arranque en frío); 0 la apaga sin tráfico.')
@minValue(0)
@maxValue(1)
param apiMinReplicas int = 0

@description('1 enciende el procesador continuo; 0 lo deja apagado y sin costo de cómputo.')
@minValue(0)
@maxValue(1)
param workerReplicas int = 0

@description('Partido de Supabase que repite el trabajo replay.')
param replayMatchId string = 'synthetic-analytics-001'

@description('Velocidad de la repetición; 1 es tiempo real.')
param replaySpeed string = '8'

var normalizedPrefix = toLower(replace(projectPrefix, '-', ''))
var resourceSuffix = uniqueString(subscription().id, resourceGroup().id, projectPrefix)
var names = {
  logs: 'log-${normalizedPrefix}-${environmentName}-${substring(resourceSuffix, 0, 6)}'
  registry: 'cr${normalizedPrefix}${resourceSuffix}'
  identity: 'id-${normalizedPrefix}-${environmentName}-analytics'
  // -wp: entorno WorkloadProfiles; el nombre anterior quedó en modo Express o suspendido.
  environment: 'cae-${normalizedPrefix}-${environmentName}-wp'
  api: 'ca-${normalizedPrefix}-api'
  worker: 'ca-${normalizedPrefix}-worker'
  web: 'ca-${normalizedPrefix}-web'
  replay: 'caj-${normalizedPrefix}-replay'
}
var tags = {
  project: 'mentox-premier-league'
  environment: environmentName
  managedBy: 'bicep'
  workload: 'analytics'
}
var hasDatabase = !empty(supabaseDbUrl)
var deployWeb = deployApps && !empty(webImage)
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

module data 'main.bicep' = {
  name: 'data-vision'
  params: {
    projectPrefix: projectPrefix
    environmentName: environmentName
    location: location
  }
}

module insights 'analytics.bicep' = {
  name: 'analytics-insights'
  params: {
    eventHubNamespaceName: data.outputs.eventHubNamespaceName
    storageAccountName: data.outputs.storageAccountName
  }
}

module community 'community.bicep' = {
  name: 'community-realtime'
  params: {
    eventHubNamespaceName: data.outputs.eventHubNamespaceName
  }
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: names.logs
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: json('0.1')
    }
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: names.registry
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: names.identity
  location: location
  tags: tags
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, acrPullRoleId)
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

module dataRoles 'modules/analytics-roles.bicep' = {
  name: 'analytics-roles'
  params: {
    principalId: identity.properties.principalId
    eventHubNamespaceName: data.outputs.eventHubNamespaceName
    storageAccountName: data.outputs.storageAccountName
  }
}

// Modo WorkloadProfiles con el perfil Consumption (pago por uso). Sin indicarlo,
// Azure crea un entorno Express, que no admite trabajos y apaga lo que no recibe HTTP.
resource environment 'Microsoft.App/managedEnvironments@2026-07-01' = {
  name: names.environment
  location: environmentLocation
  tags: tags
  properties: {
    environmentMode: 'WorkloadProfiles'
    workloadProfiles: concat([
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ], gpuWorkloadProfile ? [
      {
        // Mismo nombre que usan deploy-gpu-model-common.sh y deploy-messi-generator.sh.
        name: 'NC8as-T4'
        workloadProfileType: 'Consumption-GPU-NC8as-T4'
      }
    ] : [])
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
  }
}

var apiFqdn = '${names.api}.${environment.properties.defaultDomain}'
var registries = [
  {
    server: registry.properties.loginServer
    identity: identity.id
  }
]
var databaseSecrets = hasDatabase ? [
  {
    name: 'supabase-db-url'
    value: supabaseDbUrl
  }
] : []
var databaseEnv = hasDatabase ? [
  {
    name: 'SUPABASE_DB_URL'
    secretRef: 'supabase-db-url'
  }
] : []
// No es secreta: la API lee de ahí las claves públicas que firman las sesiones de Supabase Auth.
var editorAuthEnv = empty(supabaseUrl) ? [] : [
  {
    name: 'SUPABASE_URL'
    value: supabaseUrl
  }
]
// El estadio: la API descarga el vídeo MESSI y sus datos del Storage propio con su identidad.
var stadiumEnv = empty(visionVideoBlobName) ? [] : [
  {
    name: 'AZURE_BLOB_SERVICE_ENDPOINT'
    value: data.outputs.blobServiceEndpoint
  }
  {
    name: 'VISION_VIDEO_CONTAINER'
    value: 'authorized-videos'
  }
  {
    name: 'VISION_VIDEO_BLOB_NAME'
    value: visionVideoBlobName
  }
]
// Modelos del estadio: los endpoints van como variables y las claves como secretos.
var hasModels = !empty(roboflowEndpoint) && !empty(roboflowApiKey) && !empty(teamspottingEndpoint) && !empty(teamspottingApiKey)
var modelSecrets = hasModels ? [
  {
    name: 'roboflow-api-key'
    value: roboflowApiKey
  }
  {
    name: 'teamspotting-api-key'
    value: teamspottingApiKey
  }
] : []
var modelEnv = hasModels ? [
  {
    name: 'ROBOFLOW_SUITE_ENDPOINT'
    value: roboflowEndpoint
  }
  {
    name: 'ROBOFLOW_SUITE_API_KEY'
    secretRef: 'roboflow-api-key'
  }
  {
    name: 'SOCCERNET_ENDPOINT'
    value: teamspottingEndpoint
  }
  {
    name: 'SOCCERNET_API_KEY'
    secretRef: 'teamspotting-api-key'
  }
  {
    name: 'SOCCERNET_TIMEOUT_SECONDS'
    value: '1800'
  }
] : []
var azureEnv = [
  {
    name: 'AZURE_CLIENT_ID'
    value: identity.properties.clientId
  }
  {
    name: 'EVENT_HUB_FULLY_QUALIFIED_NAMESPACE'
    value: data.outputs.eventHubFullyQualifiedNamespace
  }
  {
    name: 'EVENT_HUB_NAME'
    value: data.outputs.eventHubName
  }
  {
    name: 'INSIGHTS_EVENT_HUB_NAME'
    value: insights.outputs.insightsEventHubName
  }
  {
    name: 'AZURE_BLOB_SERVICE_ENDPOINT'
    value: data.outputs.blobServiceEndpoint
  }
]

resource api 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: names.api
  location: environmentLocation
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  dependsOn: [
    acrPull
  ]
  properties: {
    managedEnvironmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
      registries: registries
      secrets: concat(databaseSecrets, modelSecrets)
    }
    template: {
      containers: [
        {
          name: 'api'
          image: apiImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: concat([
            {
              name: 'ANALYTICS_ENGINE'
              value: 'persona2'
            }
            {
              name: 'MATCH_SOURCE'
              value: hasDatabase ? 'supabase' : 'synthetic'
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: identity.properties.clientId
            }
            {
              // Votos, sugerencias y chat de la comunidad viajan por Event Hubs.
              name: 'COMMUNITY_TRANSPORT'
              value: 'azure_event_hubs'
            }
            {
              name: 'EVENT_HUB_FULLY_QUALIFIED_NAMESPACE'
              value: data.outputs.eventHubFullyQualifiedNamespace
            }
            {
              name: 'COMMUNITY_EVENT_HUB_NAME'
              value: community.outputs.communityEventHubName
            }
            {
              name: 'COMMUNITY_EVENT_HUB_CONSUMER_GROUP'
              value: community.outputs.communityConsumerGroup
            }
          ], databaseEnv, editorAuthEnv, stadiumEnv, modelEnv)
          probes: [
            {
              // /matches carga los partidos (y su seguimiento) antes de recibir tráfico.
              type: 'Startup'
              httpGet: {
                path: '/api/v1/matches'
                port: 8000
              }
              initialDelaySeconds: 5
              periodSeconds: 10
              timeoutSeconds: 60
              failureThreshold: 10
            }
            {
              type: 'Liveness'
              httpGet: {
                path: '/api/v1/health'
                port: 8000
              }
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
            }
          ]
        }
      ]
      scale: {
        // Una sola réplica: la API guarda en memoria la revisión editorial y los reportes.
        minReplicas: apiMinReplicas
        maxReplicas: 1
      }
    }
  }
}

resource worker 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: names.worker
  location: environmentLocation
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  dependsOn: [
    acrPull
    dataRoles
  ]
  properties: {
    managedEnvironmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: databaseSecrets
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: apiImage
          command: [
            'python'
            'scripts/analytics_stream_worker.py'
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: concat(azureEnv, [
            {
              name: 'EVENT_HUB_CONSUMER_GROUP'
              value: 'backend'
            }
            {
              name: 'ANALYTICS_IDLE_SECONDS'
              value: '30'
            }
          ], databaseEnv)
        }
      ]
      scale: {
        minReplicas: workerReplicas
        maxReplicas: 1
      }
    }
  }
}

resource replay 'Microsoft.App/jobs@2024-03-01' = if (deployApps && hasDatabase) {
  name: names.replay
  location: environmentLocation
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  dependsOn: [
    acrPull
    dataRoles
  ]
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 3600
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      registries: registries
      secrets: databaseSecrets
    }
    template: {
      containers: [
        {
          name: 'replay'
          image: apiImage
          command: [
            'python'
            'scripts/replay_match_to_event_hubs.py'
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: concat(azureEnv, [
            {
              name: 'REPLAY_MATCH_ID'
              value: replayMatchId
            }
            {
              name: 'REPLAY_SPEED'
              value: replaySpeed
            }
          ], databaseEnv)
        }
      ]
    }
  }
}

resource web 'Microsoft.App/containerApps@2024-03-01' = if (deployWeb) {
  name: names.web
  location: environmentLocation
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  dependsOn: [
    acrPull
  ]
  properties: {
    managedEnvironmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        allowInsecure: false
      }
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'web'
          image: webImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            {
              name: 'API_UPSTREAM'
              value: 'https://${apiFqdn}'
            }
            {
              name: 'API_HOST'
              value: apiFqdn
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

output registryName string = registry.name
output registryLoginServer string = registry.properties.loginServer
output containerAppsEnvironmentName string = environment.name
output identityClientId string = identity.properties.clientId
output apiAppName string = names.api
output workerAppName string = names.worker
output webAppName string = names.web
output replayJobName string = names.replay
output apiUrl string = 'https://${apiFqdn}'
output webUrl string = deployWeb ? 'https://${names.web}.${environment.properties.defaultDomain}' : ''
output databaseConfigured bool = hasDatabase
output editorAuthConfigured bool = !empty(supabaseUrl)
output stadiumConfigured bool = !empty(visionVideoBlobName)
output stadiumModelsConfigured bool = hasModels
output eventHubNamespaceName string = data.outputs.eventHubNamespaceName
output eventHubFullyQualifiedNamespace string = data.outputs.eventHubFullyQualifiedNamespace
output insightsEventHubName string = insights.outputs.insightsEventHubName
output storageAccountName string = data.outputs.storageAccountName
output blobServiceEndpoint string = data.outputs.blobServiceEndpoint

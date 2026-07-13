// =============================================================================
// Znuny on Azure Container Apps — infrastructure as code
//
// Provisions:
//   - Log Analytics workspace          (Container Apps logs)
//   - Azure Container Registry (ACR)   (holds the Znuny image)
//   - Azure Database for MySQL         (Flexible Server + database)
//   - Container Apps Environment
//   - Container App (Znuny web + daemon)
//
// Deploy:
//   az deployment group create \
//     -g <resource-group> \
//     -f deploy/azure/main.bicep \
//     -p deploy/azure/main.parameters.json \
//     -p mysqlAdminPassword='<strong-password>'
// =============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix used to name resources (lowercase letters/numbers).')
@minLength(3)
@maxLength(11)
param namePrefix string = 'znuny'

@description('Container image reference. Leave as the placeholder for the first deployment; the CI pipeline updates it to the ACR image afterwards.')
param containerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

// --- Database ----------------------------------------------------------------
@description('MySQL administrator login name.')
param mysqlAdminUser string = 'znunyadmin'

@description('MySQL administrator password.')
@secure()
param mysqlAdminPassword string

@description('Znuny application database name.')
param znunyDbName string = 'znuny'

@description('MySQL Flexible Server compute SKU.')
param mysqlSkuName string = 'Standard_B1ms'

@description('MySQL Flexible Server tier.')
@allowed([ 'Burstable', 'GeneralPurpose', 'MemoryOptimized' ])
param mysqlTier string = 'Burstable'

@description('MySQL storage size in GB.')
param mysqlStorageGb int = 32

@description('Require TLS for MySQL connections. The Debian DBD::mysql driver (linked against the MariaDB connector) cannot enforce TLS, so this defaults to OFF: the server still accepts TLS when the client negotiates it, but also allows plaintext. Set to true once connections run over a private VNet or a TLS-capable driver.')
param mysqlRequireSecureTransport bool = false

// --- Container App sizing -----------------------------------------------------
@description('vCPU allocated to the Znuny container.')
param containerCpu string = '1.0'

@description('Memory allocated to the Znuny container.')
param containerMemory string = '2Gi'

@description('Minimum number of replicas. Keep at 1 so the Znuny daemon stays running.')
param minReplicas int = 1

@description('Maximum number of replicas.')
param maxReplicas int = 3

@description('Custom public domain for the app (e.g. znuny.trf3.jus.br). Leave empty to use the default *.azurecontainerapps.io hostname. When set, an Azure-managed TLS certificate is issued and Znuny advertises this hostname. The DNS records (CNAME + asuid TXT) must already exist before deploying with this set.')
param customDomain string = ''

// -----------------------------------------------------------------------------
var uniqueSuffix = uniqueString(resourceGroup().id)
var acrName = toLower('${namePrefix}acr${uniqueSuffix}')
var logAnalyticsName = '${namePrefix}-logs'
var envName = '${namePrefix}-env'
var mysqlServerName = toLower('${namePrefix}-mysql-${uniqueSuffix}')
var appName = '${namePrefix}-web'

// --- Log Analytics -----------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// --- Azure Container Registry ------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: true
  }
}

// --- MySQL Flexible Server ---------------------------------------------------
resource mysql 'Microsoft.DBforMySQL/flexibleServers@2023-12-30' = {
  name: mysqlServerName
  location: location
  sku: {
    name: mysqlSkuName
    tier: mysqlTier
  }
  properties: {
    administratorLogin: mysqlAdminUser
    administratorLoginPassword: mysqlAdminPassword
    version: '8.0.21'
    storage: {
      storageSizeGB: mysqlStorageGb
      autoGrow: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// Allow other Azure services (incl. Container Apps) to reach the server.
resource mysqlAllowAzure 'Microsoft.DBforMySQL/flexibleServers/firewallRules@2023-12-30' = {
  parent: mysql
  name: 'AllowAllAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Znuny needs a larger packet size for attachments and a suitable row format.
resource mysqlMaxPacket 'Microsoft.DBforMySQL/flexibleServers/configurations@2023-12-30' = {
  parent: mysql
  name: 'max_allowed_packet'
  properties: {
    value: '67108864'
    source: 'user-override'
  }
  dependsOn: [ mysqlAllowAzure ]
}

// Control TLS enforcement. See mysqlRequireSecureTransport for the rationale.
resource mysqlSecureTransport 'Microsoft.DBforMySQL/flexibleServers/configurations@2023-12-30' = {
  parent: mysql
  name: 'require_secure_transport'
  properties: {
    value: mysqlRequireSecureTransport ? 'ON' : 'OFF'
    source: 'user-override'
  }
  dependsOn: [ mysqlMaxPacket ]
}

resource znunyDb 'Microsoft.DBforMySQL/flexibleServers/databases@2023-12-30' = {
  parent: mysql
  name: znunyDbName
  properties: {
    charset: 'utf8mb4'
    collation: 'utf8mb4_general_ci'
  }
}

// --- Container Apps Environment ----------------------------------------------
resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// NOTE: The custom hostname binding and its Azure-managed certificate are NOT
// created here. Container Apps requires a specific ordering (add hostname, then
// issue the managed certificate, then enable the SNI binding) that cannot be
// expressed in a single Bicep pass. provision.sh performs those steps via the
// CLI after deployment. This template only advertises the hostname to Znuny
// (ZNUNY_FQDN) so it builds correct absolute links.

// Base container environment variables; ZNUNY_FQDN is appended when a custom
// domain is configured so Znuny builds correct absolute links.
var baseEnv = [
  { name: 'ZNUNY_DB_HOST', value: mysql.properties.fullyQualifiedDomainName }
  { name: 'ZNUNY_DB_PORT', value: '3306' }
  { name: 'ZNUNY_DB_NAME', value: znunyDbName }
  { name: 'ZNUNY_DB_USER', value: mysqlAdminUser }
  { name: 'ZNUNY_DB_PASSWORD', secretRef: 'db-password' }
  { name: 'ZNUNY_DB_SSL', value: 'required' }
  { name: 'ZNUNY_HTTP_TYPE', value: 'https' }
]
var appEnv = empty(customDomain) ? baseEnv : concat(baseEnv, [
  { name: 'ZNUNY_FQDN', value: customDomain }
])

// --- Container App ------------------------------------------------------------
resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        traffic: [
          { latestRevision: true, weight: 100 }
        ]
      }
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
        {
          name: 'db-password'
          value: mysqlAdminPassword
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'znuny'
          image: containerImage
          resources: {
            cpu: json(containerCpu)
            memory: containerMemory
          }
          env: appEnv
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/znuny/index.pl', port: 8080 }
              initialDelaySeconds: 60
              periodSeconds: 30
              failureThreshold: 5
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-scaling'
            http: { metadata: { concurrentRequests: '50' } }
          }
        ]
      }
    }
  }
  dependsOn: [ znunyDb ]
}

// --- Outputs -----------------------------------------------------------------
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output containerAppName string = app.name
output mysqlFqdn string = mysql.properties.fullyQualifiedDomainName
output appUrl string = 'https://${app.properties.configuration.ingress.fqdn}'
output defaultFqdn string = app.properties.configuration.ingress.fqdn
// Value for the "asuid.<subdomain>" TXT record used to validate the custom domain.
output customDomainVerificationId string = app.properties.customDomainVerificationId
output customDomainUrl string = empty(customDomain) ? '' : 'https://${customDomain}'

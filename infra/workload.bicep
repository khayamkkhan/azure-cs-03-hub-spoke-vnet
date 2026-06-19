// =============================================================================
// workload.bicep — "Contoso WebApp" persistent workload for Project 03
// Deploys: App Service (B1, VNet-integrated) + Azure SQL (Basic) + Key Vault
//          + Application Insights, all logging to log-portfolio-baseline.
// Scope:   resource group  (deploy into rg-contoso-webapp — PERSISTENT, kept through P07)
// Region:  eastus
// Depends: network.bicep already deployed (uses its snet-appsvc subnet).
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region — must match the baseline workspace')
param location string = resourceGroup().location

@description('Region for the SQL server/db. Defaults to the main region; override to eastus2 etc. when eastus SQL capacity is restricted ("RegionDoesNotAllowProvisioning").')
param sqlLocation string = location

@description('Resource group holding the hub-spoke network (for the App Service integration subnet)')
param networkResourceGroup string = 'rg-network-lab'

@description('Resource group holding the baseline Log Analytics workspace')
param baselineResourceGroup string = 'rg-portfolio-baseline'

@description('Baseline Log Analytics workspace name')
param workspaceName string = 'log-portfolio-baseline'

@description('SQL administrator login')
param sqlAdminLogin string = 'sqladmin'

@description('SQL administrator password — supplied via env var (export SQL_ADMIN_PASSWORD=...)')
@secure()
param sqlAdminPassword string

@description('Common tags — keys required by the baseline tag policy')
param tags object = {
  owner: 'khayam'
  environment: 'lab'
  project: 'contoso-webapp'
}

// ---------- existing baseline workspace (cross-RG) ----------
resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
  scope: resourceGroup(baselineResourceGroup)
}

// ---------- App Service VNet-integration subnet (cross-RG, deterministic id) ----------
var appsvcSubnetId = resourceId(
  networkResourceGroup,
  'Microsoft.Network/virtualNetworks/subnets',
  'vnet-spoke-workload',
  'snet-appsvc'
)

var suffix = uniqueString(resourceGroup().id)

// ==================== Application Insights (workspace-based) ====================
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'ai-contoso-webapp'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// ==================== Azure SQL ====================
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-contoso-${suffix}'
  location: sqlLocation
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled' // P04 removes this and adds a Private Endpoint
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: 'db-contoso'
  location: sqlLocation
  tags: tags
  sku: { name: 'Basic', tier: 'Basic', capacity: 5 }
}

// Allow Azure services (incl. App Service) to reach SQL while public access is on (P03 only)
resource sqlAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

// Server auditing -> Azure Monitor (feeds SQLSecurityAuditEvents to Log Analytics in P05)
resource sqlAudit 'Microsoft.Sql/servers/auditingSettings@2023-08-01-preview' = {
  parent: sqlServer
  name: 'default'
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
  }
}

// Audit log routing lives on the special 'master' database
resource sqlMaster 'Microsoft.Sql/servers/databases@2023-08-01-preview' existing = {
  parent: sqlServer
  name: 'master'
}

resource sqlAuditToLaw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: sqlMaster
  name: 'to-law'
  properties: {
    workspaceId: law.id
    logs: [
      { category: 'SQLSecurityAuditEvents', enabled: true }
    ]
  }
}

// ==================== Key Vault ====================
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-contoso${suffix}' // <=24 chars
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: tenant().tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForTemplateDeployment: true
    accessPolicies: [] // app identity policy added after the app exists (below)
  }
}

resource sqlConnSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'SqlConnectionString'
  properties: {
    value: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${sqlDatabase.name};Persist Security Info=False;User ID=${sqlAdminLogin};Password=${sqlAdminPassword};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
  }
}

resource kvAuditToLaw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: keyVault
  name: 'to-law'
  properties: {
    workspaceId: law.id
    logs: [
      { category: 'AuditEvent', enabled: true }
    ]
  }
}

// ==================== App Service ====================
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-contoso-webapp'
  location: location
  tags: tags
  sku: { name: 'B1', tier: 'Basic' }
  kind: 'linux'
  properties: { reserved: true } // Linux plan
}

resource appService 'Microsoft.Web/sites@2023-12-01' = {
  name: 'app-contoso-${suffix}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    virtualNetworkSubnetId: appsvcSubnetId // regional VNet integration -> snet-appsvc
    siteConfig: {
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      ftpsState: 'Disabled'
      linuxFxVersion: 'DOTNETCORE|8.0'
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'SQLDB_CONNECTIONSTRING'
          value: '@Microsoft.KeyVault(SecretUri=${sqlConnSecret.properties.secretUri})'
        }
      ]
    }
  }
}

// Grant the App Service managed identity read access to the vault's secrets
resource kvAppPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  parent: keyVault
  name: 'add'
  properties: {
    accessPolicies: [
      {
        tenantId: tenant().tenantId
        objectId: appService.identity.principalId
        permissions: { secrets: ['get', 'list'] }
      }
    ]
  }
}

resource appDiagToLaw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: appService
  name: 'to-law'
  properties: {
    workspaceId: law.id
    logs: [
      { category: 'AppServiceHTTPLogs', enabled: true }
      { category: 'AppServiceConsoleLogs', enabled: true }
    ]
  }
}

// ==================== Outputs ====================
output appServiceName string = appService.name
output appServiceUrl string = 'https://${appService.properties.defaultHostName}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output keyVaultName string = keyVault.name
output appInsightsName string = appInsights.name

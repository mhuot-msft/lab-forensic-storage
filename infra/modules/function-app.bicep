// Function App for automated evidence hashing (Elastic Premium with VNet integration)

@description('Azure region')
param location string

@description('Name prefix for resources')
param namePrefix string

@description('Storage account name for the forensic evidence')
param forensicStorageAccountName string

@description('Log Analytics workspace ID for Application Insights')
param logAnalyticsWorkspaceId string

@description('Tags to apply')
param tags object = {}

var functionAppName = 'func-${namePrefix}-hash'
var appServicePlanName = 'asp-${namePrefix}-hash'
var appInsightsName = 'ai-${namePrefix}-hash'
var funcStorageAccountName = '${namePrefix}func${uniqueString(resourceGroup().id)}'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

// Storage account for Function App runtime — separate from forensic evidence stores.
// Uses identity-based access (no shared keys) for sandbox/managed environment compatibility.
resource funcStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: take(funcStorageAccountName, 24)
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: false
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  kind: 'elastic'
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
  }
  properties: {
    maximumElasticWorkerCount: 3
    reserved: true
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    // VNet integration is added by deploy.ps1 AFTER function code is deployed.
    // Deploying VNet with the app shell causes VNETFailure race conditions on EP1.
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: funcStorageAccount.name
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AzureWebJobsFeatureFlags'
          value: 'EnableWorkerIndexing'
        }
      ]
    }
  }
}

// Reference the forensic storage account to scope RBAC
resource forensicStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: forensicStorageAccountName
}

// Grant Function App managed identity Blob Data Contributor on the entire forensic
// storage account — the function reads from forensic-evidence and writes hash
// receipts to chain-of-custody, so it needs access to both containers.
resource functionRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(forensicStorageAccount.id, functionApp.id, storageBlobDataContributorRoleId)
  scope: forensicStorageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Identity-based AzureWebJobsStorage: Function runtime needs these roles on its own storage account
resource funcStorageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcStorageAccount.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: funcStorageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcStorageAccount.id, functionApp.id, storageQueueDataContributorRoleId)
  scope: funcStorageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcStorageAccount.id, functionApp.id, storageTableDataContributorRoleId)
  scope: funcStorageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppId string = functionApp.id
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId

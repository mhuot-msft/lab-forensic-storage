// RBAC assignment for Function App managed identity on a forensic-evidence container

@description('Storage account name containing the forensic-evidence container')
param storageAccountName string

@description('Principal ID of the Function App managed identity')
param functionAppPrincipalId string

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource forensicContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: blobServices
  name: 'forensic-evidence'
}

resource functionRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(forensicContainer.id, functionAppPrincipalId, storageBlobDataContributorRoleId)
  scope: forensicContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

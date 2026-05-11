// RBAC: Storage Blob Data Contributor for investigators on the entire storage account.
// Investigators need access to both forensic-evidence (upload/read evidence) and
// chain-of-custody (read hash receipts for integrity verification).

@description('Array of investigator principal IDs to assign Contributor role')
param investigatorPrincipalIds array

@description('Principal type for RBAC: User, Group, or ServicePrincipal')
param principalType string = 'User'

@description('Name of the storage account')
param storageAccountName string

var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource contributorAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (principalId, i) in investigatorPrincipalIds: {
    name: guid(storageAccount.id, principalId, storageBlobDataContributorRoleId)
    scope: storageAccount
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
      principalId: principalId
      principalType: principalType
    }
  }
]

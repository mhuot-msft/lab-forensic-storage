// Forensic storage account with versioning, soft delete, TLS 1.2, and keys disabled

@description('Azure region for the storage account')
param location string

@description('Name of the storage account')
param storageAccountName string

@description('Enable ADLS Gen2 hierarchical namespace for real folder semantics and ACL readiness')
param enableHierarchicalNamespace bool = true

@description('Number of days for blob soft delete retention')
param blobSoftDeleteRetentionDays int = 90

@description('Number of days for container soft delete retention')
param containerSoftDeleteRetentionDays int = 90

@description('Tags to apply to all resources')
param tags object = {}

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: enableHierarchicalNamespace
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    supportsHttpsTrafficOnly: true
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    // Versioning not supported on HNS accounts without feature flag registration
    isVersioningEnabled: !enableHierarchicalNamespace
    deleteRetentionPolicy: {
      enabled: true
      days: blobSoftDeleteRetentionDays
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: containerSoftDeleteRetentionDays
    }
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output blobServicesId string = blobServices.id

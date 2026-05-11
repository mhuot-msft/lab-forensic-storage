// Main orchestration template for the forensic storage lab
targetScope = 'subscription'

@description('Azure region for all resources')
param location string

@description('Name of the resource group')
param resourceGroupName string

@description('Name prefix for resources')
param namePrefix string = 'forensiclab'

@description('VNet address space')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix for private endpoints')
param subnetAddressPrefix string = '10.0.0.0/24'

@description('Blob soft delete retention in days')
param blobSoftDeleteRetentionDays int = 90

@description('Container soft delete retention in days')
param containerSoftDeleteRetentionDays int = 90

@description('Immutability retention period in days')
param retentionDays int = 365

@description('Days after last modification to move blobs to Cool tier')
param hotToCoolDays int = 60

@description('Days after last modification to move blobs to Archive tier')
param coolToArchiveDays int = 730

@description('Array of investigator principal IDs for RBAC assignments')
param investigatorPrincipalIds array

@description('Principal type for RBAC: User, Group, or ServicePrincipal')
param principalType string = 'User'

@description('Enable optional SIEM export via Event Hub')
param enableSiemExport bool = false

@description('Deploy Event Grid subscription (requires function code to be deployed first)')
param deployEventGrid bool = true

@description('Tags to apply to all resources')
param tags object = {
  project: 'forensic-storage-lab'
  environment: 'demo'
}

// Derived names
var uniqueSuffix = uniqueString(rg.id)
var storageAccountName = take('${namePrefix}${uniqueSuffix}', 24)
var storageTags = union(tags, {
  displayName: 'Forensic Evidence Store'
})
var vnetName = 'vnet-${namePrefix}'
var privateEndpointName = 'pe-${namePrefix}-blob'
var dfsPeEndpointName = 'pe-${namePrefix}-dfs'
var workspaceName = 'law-${namePrefix}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module networking 'modules/networking.bicep' = {
  name: 'networking'
  scope: rg
  params: {
    location: location
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
    subnetAddressPrefix: subnetAddressPrefix
    tags: tags
  }
}

module privateDns 'modules/private-dns.bicep' = {
  name: 'private-dns'
  scope: rg
  params: {
    vnetId: networking.outputs.vnetId
    subResource: 'blob'
    tags: tags
  }
}

module privateDnsDfs 'modules/private-dns.bicep' = {
  name: 'private-dns-dfs'
  scope: rg
  params: {
    vnetId: networking.outputs.vnetId
    subResource: 'dfs'
    tags: tags
  }
}

module storageAccount 'modules/storage-account.bicep' = {
  name: 'storage-account'
  scope: rg
  params: {
    location: location
    storageAccountName: storageAccountName
    enableHierarchicalNamespace: true
    blobSoftDeleteRetentionDays: blobSoftDeleteRetentionDays
    containerSoftDeleteRetentionDays: containerSoftDeleteRetentionDays
    tags: storageTags
  }
}

module privateEndpoint 'modules/private-endpoint.bicep' = {
  name: 'private-endpoint'
  scope: rg
  params: {
    location: location
    privateEndpointName: privateEndpointName
    storageAccountId: storageAccount.outputs.storageAccountId
    subnetId: networking.outputs.subnetId
    privateDnsZoneId: privateDns.outputs.privateDnsZoneId
    tags: tags
  }
}

module dfsPrivateEndpoint 'modules/private-endpoint.bicep' = {
  name: 'dfs-private-endpoint'
  scope: rg
  params: {
    location: location
    privateEndpointName: dfsPeEndpointName
    storageAccountId: storageAccount.outputs.storageAccountId
    subnetId: networking.outputs.subnetId
    privateDnsZoneId: privateDnsDfs.outputs.privateDnsZoneId
    subResource: 'dfs'
    tags: tags
  }
}

module containers 'modules/containers.bicep' = {
  name: 'containers'
  scope: rg
  params: {
    storageAccountName: storageAccount.outputs.storageAccountName
    retentionDays: retentionDays
  }
}

module lifecycle 'modules/lifecycle.bicep' = {
  name: 'lifecycle'
  scope: rg
  params: {
    storageAccountName: storageAccount.outputs.storageAccountName
    hotToCoolDays: hotToCoolDays
    coolToArchiveDays: coolToArchiveDays
  }
  dependsOn: [
    containers
  ]
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    workspaceName: workspaceName
    storageAccountName: storageAccount.outputs.storageAccountName
    tags: tags
  }
}

module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  scope: rg
  params: {
    storageAccountName: storageAccount.outputs.storageAccountName
    investigatorPrincipalIds: investigatorPrincipalIds
    principalType: principalType
  }
  dependsOn: [
    containers
  ]
}

module siemExport 'modules/siem-export.bicep' = if (enableSiemExport) {
  name: 'siem-export'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    storageAccountName: storageAccount.outputs.storageAccountName
    tags: tags
  }
}

module functionApp 'modules/function-app.bicep' = {
  name: 'function-app'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    forensicStorageAccountName: storageAccount.outputs.storageAccountName
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
  dependsOn: [
    containers
  ]
}

module eventGrid 'modules/event-grid.bicep' = if (deployEventGrid) {
  name: 'event-grid'
  scope: rg
  params: {
    storageAccountName: storageAccount.outputs.storageAccountName
    hashFunctionId: functionApp.outputs.functionAppId
  }
}

output storageAccountName string = storageAccount.outputs.storageAccountName
output vnetName string = networking.outputs.vnetName
output logAnalyticsWorkspaceName string = monitoring.outputs.logAnalyticsWorkspaceName
output resourceGroupName string = rg.name

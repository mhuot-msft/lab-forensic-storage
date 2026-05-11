// Private endpoint for a storage account sub-resource (blob or dfs)

@description('Azure region for the private endpoint')
param location string

@description('Name of the private endpoint')
param privateEndpointName string

@description('Resource ID of the storage account')
param storageAccountId string

@description('Resource ID of the subnet for the private endpoint')
param subnetId string

@description('Resource ID of the private DNS zone')
param privateDnsZoneId string

@description('Storage sub-resource type: blob or dfs')
@allowed(['blob', 'dfs'])
param subResource string = 'blob'

@description('Tags to apply to all resources')
param tags object = {}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-connection'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [
            subResource
          ]
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: '${subResource}-dns-config'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output privateEndpointId string = privateEndpoint.id
output privateEndpointName string = privateEndpoint.name

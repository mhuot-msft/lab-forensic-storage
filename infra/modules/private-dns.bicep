// Private DNS zone for storage private endpoints (blob or dfs)

@description('VNet resource ID to link the DNS zone to')
param vnetId string

@description('Storage sub-resource type: blob or dfs')
@allowed(['blob', 'dfs'])
param subResource string = 'blob'

@description('Tags to apply to all resources')
param tags object = {}

var privateDnsZoneName = 'privatelink.${subResource}.${environment().suffixes.storage}'

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'link-to-vnet'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

output privateDnsZoneId string = privateDnsZone.id
output privateDnsZoneName string = privateDnsZone.name

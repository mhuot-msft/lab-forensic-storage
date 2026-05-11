// Networking module: VNet and subnets for private endpoint access.

@description('Azure region for all resources')
param location string

@description('Name of the virtual network')
param vnetName string

@description('Name of the subnet for private endpoints')
param subnetName string = 'snet-private-endpoints'

@description('VNet address space')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet address prefix')
param subnetAddressPrefix string = '10.0.0.0/24'

@description('Tags to apply to all resources')
param tags object = {}

var baseSubnets = [
  {
    name: subnetName
    properties: {
      addressPrefix: subnetAddressPrefix
      privateEndpointNetworkPolicies: 'Disabled'
    }
  }
  {
    name: 'snet-functions'
    properties: {
      addressPrefix: cidrSubnet(vnetAddressPrefix, 24, 1)
      delegations: [
        {
          name: 'Microsoft.Web.serverFarms'
          properties: {
            serviceName: 'Microsoft.Web/serverFarms'
          }
        }
      ]
    }
  }
]

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: baseSubnets
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetId string = vnet.properties.subnets[0].id
output subnetName string = vnet.properties.subnets[0].name
output functionSubnetId string = vnet.properties.subnets[1].id

targetScope = 'subscription'

@description('Azure region for the spoke resources. The hub stays in its own region; the peering is global.')
param location string = 'polandcentral'

@description('Short region token used in resource group and peering names.')
param locationShort string = 'plc'

@description('Workload name used in resource names.')
param workload string = 'hotelbooking'

@description('Environment short name.')
param environment string = 'test'

@description('Address space for the spoke VNet. Must not overlap the hub (192.168.100.0/24) or other spokes peered to it.')
param spokeAddressPrefix string = '10.21.0.0/16'

@description('Subnet for private endpoints.')
param privateEndpointSubnetPrefix string = '10.21.0.0/24'

@description('Subnet for the Container Apps environment (delegated).')
param containerAppsSubnetPrefix string = '10.21.1.0/24'

@description('Name of the hub resource group.')
param hubResourceGroupName string = 'rg-platform'

@description('Name of the hub virtual network.')
param hubVnetName string = 'vnet-hub'

var tags = {
  workload: workload
  environment: environment
  role: 'spoke'
}

var resourceGroupName = 'rg-${workload}-${environment}-${locationShort}'
var spokeVnetName = 'vnet-${workload}-${environment}-${location}-001'
var hubVnetId = resourceId(subscription().subscriptionId, hubResourceGroupName, 'Microsoft.Network/virtualNetworks', hubVnetName)

module workloadRg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'workload-rg-deployment'
  params: {
    name: resourceGroupName
    location: location
    tags: tags
  }
}

// Peering is created on both sides: spoke -> hub, and hub -> spoke via remotePeeringEnabled.
module spokeVnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'spoke-vnet-deployment'
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    workloadRg
  ]
  params: {
    name: spokeVnetName
    location: location
    tags: tags
    addressPrefixes: [
      spokeAddressPrefix
    ]
    subnets: [
      {
        name: 'snet-private-endpoints'
        addressPrefix: privateEndpointSubnetPrefix
      }
      {
        name: 'snet-containerapps'
        addressPrefix: containerAppsSubnetPrefix
        delegation: 'Microsoft.App/environments'
      }
    ]
    peerings: [
      {
        name: 'peer-${workload}-${environment}-${locationShort}-to-hub'
        remoteVirtualNetworkResourceId: hubVnetId
        allowForwardedTraffic: true
        allowVirtualNetworkAccess: true
        remotePeeringEnabled: true
        remotePeeringName: 'peer-hub-to-${workload}-${environment}-${locationShort}'
        remotePeeringAllowForwardedTraffic: true
        remotePeeringAllowVirtualNetworkAccess: true
      }
    ]
  }
}

output resourceGroupName string = resourceGroupName
output spokeVnetId string = spokeVnet.outputs.resourceId
output spokeVnetName string = spokeVnet.outputs.name

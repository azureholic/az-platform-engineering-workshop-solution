using 'main.bicep'

param environment = 'test'
param locationShort = 'plc'
param spokeAddressPrefix = '10.21.0.0/16'
param privateEndpointSubnetPrefix = '10.21.0.0/24'
param containerAppsSubnetPrefix = '10.21.1.0/24'
param privateDnsExtraLinkVnets = [
  {
    resourceGroupName: 'rg-platform'
    name: 'vnet-hub'
  }
]
param zoneRedundant = false
param minReplicas = 0
param maxReplicas = 3
param containerCpu = '0.5'
param containerMemory = '1Gi'
param sqlSkuName = 'GP_S_Gen5'
param sqlCapacity = 1
param sqlMinCapacity = '0.5'
param sqlAutoPauseDelay = 60
param logRetentionInDays = 30

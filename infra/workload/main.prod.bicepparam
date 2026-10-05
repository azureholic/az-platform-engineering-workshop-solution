using 'main.bicep'

param environment = 'prod'
param locationShort = 'plc'
param spokeAddressPrefix = '10.22.0.0/16'
param privateEndpointSubnetPrefix = '10.22.0.0/24'
param containerAppsSubnetPrefix = '10.22.1.0/24'
// The hub is already linked to the test zone of the same namespace; prod resolves through its own spoke only.
param privateDnsExtraLinkVnets = []
param zoneRedundant = true
param minReplicas = 3
param maxReplicas = 6
param containerCpu = '1.0'
param containerMemory = '2Gi'
param sqlSkuName = 'GP_S_Gen5'
param sqlCapacity = 2
param sqlMinCapacity = '1'
param sqlAutoPauseDelay = -1
param logRetentionInDays = 90

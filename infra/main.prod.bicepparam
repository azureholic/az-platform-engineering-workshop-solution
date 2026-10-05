using 'main.bicep'

param location = 'polandcentral'
param locationShort = 'plc'
param environment = 'prod'
param spokeAddressPrefix = '10.22.0.0/16'
param privateEndpointSubnetPrefix = '10.22.0.0/24'
param containerAppsSubnetPrefix = '10.22.1.0/24'

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------------------------
// HotelBooking workload (test environment) — lands in the existing spoke VNet.
// Design: docs/design-test.md
// ---------------------------------------------------------------------------------------------

@description('Azure region for the workload resources.')
param location string = resourceGroup().location

@description('Workload name used in resource names.')
@minLength(3)
param workload string = 'hotelbooking'

@description('Environment token embedded in every resource name.')
@allowed([
  'test'
  'prod'
])
param environment string = 'test'

@description('Short region token for names with tight length limits (container apps, SQL server).')
@minLength(2)
@maxLength(6)
param locationShort string = 'plc'

@description('Instance number appended to names.')
param instance string = '001'

@description('Name of the spoke virtual network.')
param spokeVnetName string = 'vnet-${workload}-${environment}-${location}-${instance}'

@description('Address space of the spoke. Must not overlap the hub or any other spoke peered to it.')
param spokeAddressPrefix string = '10.21.0.0/16'

@description('Name of the subnet that holds private endpoints.')
param privateEndpointSubnetName string = 'snet-private-endpoints'

@description('Address prefix of the private endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.21.0.0/24'

@description('Name of the Container Apps subnet.')
param containerAppsSubnetName string = 'snet-containerapps'

@description('Address prefix of the Container Apps subnet; must sit inside the spoke address space.')
param containerAppsSubnetPrefix string = '10.21.1.0/24'

@description('Resource group of the hub virtual network.')
param hubResourceGroupName string = 'rg-platform'

@description('Name of the hub virtual network.')
param hubVnetName string = 'vnet-hub'

@description('Additional VNets (besides the spoke) linked to the SQL Private DNS zone for resolution. A VNet can be linked to only one zone per namespace.')
param privateDnsExtraLinkVnets array = [
  {
    resourceGroupName: 'rg-platform'
    name: 'vnet-hub'
  }
]

@description('Zone redundancy for the Container Apps environment and the SQL database.')
param zoneRedundant bool = false

@description('Backend container image.')
param backendImage string = 'ghcr.io/azureholic/az-platform-engineering-workshop/backend:latest'

@description('Frontend container image.')
param frontendImage string = 'ghcr.io/azureholic/az-platform-engineering-workshop/frontend:latest'

@description('Container CPU cores per replica (as a string, e.g. 0.5).')
param containerCpu string = '0.5'

@description('Container memory per replica.')
param containerMemory string = '1Gi'

@description('Minimum replicas per container app (0 = scale to zero).')
@minValue(0)
param minReplicas int = 0

@description('Maximum replicas per container app.')
@minValue(1)
param maxReplicas int = 3

@description('SQL database SKU name (serverless).')
param sqlSkuName string = 'GP_S_Gen5'

@description('SQL database vCore capacity (max vCores).')
param sqlCapacity int = 1

@description('SQL serverless minimum vCores.')
param sqlMinCapacity string = '0.5'

@description('Minutes of inactivity before the serverless SQL database auto-pauses.')
param sqlAutoPauseDelay int = 60

@description('Log Analytics retention in days.')
param logRetentionInDays int = 30

var tags = {
  workload: workload
  environment: environment
  role: 'spoke'
}

var suffix = '${workload}-${environment}-${locationShort}-${instance}'
var identityName = 'id-hotelapi-${environment}-${locationShort}-${instance}'
var logName = 'log-${suffix}'
var appInsightsName = 'appi-${suffix}'
var environmentName = 'cae-${suffix}'
var backendAppName = 'ca-hotelapi-${environment}-${locationShort}-${instance}'
var frontendAppName = 'ca-hotelweb-${environment}-${locationShort}-${instance}'
// SQL server names are globally unique, so a deterministic suffix is appended.
var sqlServerName = 'sql-${workload}-${environment}-${locationShort}-${uniqueString(subscription().subscriptionId, resourceGroup().id)}'
var sqlDatabaseName = 'sqldb-${workload}-${environment}'
var sqlPrivateEndpointName = 'pep-sql-${suffix}'
var sqlPrivateDnsZoneName = 'privatelink${az.environment().suffixes.sqlServerHostname}'
var hubVnetId = resourceId(subscription().subscriptionId, hubResourceGroupName, 'Microsoft.Network/virtualNetworks', hubVnetName)

module spokeVnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'spoke-vnet-deployment'
  params: {
    name: spokeVnetName
    location: location
    tags: tags
    addressPrefixes: [
      spokeAddressPrefix
    ]
    subnets: [
      {
        name: privateEndpointSubnetName
        addressPrefix: privateEndpointSubnetPrefix
      }
      {
        name: containerAppsSubnetName
        addressPrefix: containerAppsSubnetPrefix
        delegation: 'Microsoft.App/environments'
      }
    ]
    // Peering is created on both sides: spoke -> hub, and hub -> spoke via remotePeeringEnabled.
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

var privateEndpointSubnetId = '${spokeVnet.outputs.resourceId}/subnets/${privateEndpointSubnetName}'
var containerAppsSubnetId = '${spokeVnet.outputs.resourceId}/subnets/${containerAppsSubnetName}'

// ---------------------------------------------------------------------------------------------
// Identity: runtime user-assigned managed identity for the backend (also the SQL Entra admin)
// ---------------------------------------------------------------------------------------------

module backendIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'id-hotelapi-deployment'
  params: {
    name: identityName
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------------------------
// Monitor stack — intentionally public (workshop requirement); no private networking.
// ---------------------------------------------------------------------------------------------

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'log-deployment'
  params: {
    name: logName
    location: location
    tags: tags
    dataRetention: logRetentionInDays
  }
}

module appInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'appi-deployment'
  params: {
    name: appInsightsName
    location: location
    tags: tags
    workspaceResourceId: logAnalytics.outputs.resourceId
    kind: 'web'
    applicationType: 'web'
  }
}

// ---------------------------------------------------------------------------------------------
// Private DNS (distributed model): zone lives in this RG, linked to the spoke and the hub.
// ---------------------------------------------------------------------------------------------

module sqlPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'pdns-sql-deployment'
  params: {
    name: sqlPrivateDnsZoneName
    tags: tags
    virtualNetworkLinks: concat(
      [
        {
          name: 'link-${spokeVnetName}'
          virtualNetworkResourceId: spokeVnet.outputs.resourceId
          registrationEnabled: true
        }
      ],
      map(privateDnsExtraLinkVnets, v => {
        name: 'link-${v.name}'
        virtualNetworkResourceId: resourceId(subscription().subscriptionId, v.resourceGroupName, 'Microsoft.Network/virtualNetworks', v.name)
        registrationEnabled: false
      })
    )
  }
}

// ---------------------------------------------------------------------------------------------
// Azure SQL: private endpoint only, Entra-only, backend managed identity is the Entra admin.
// ---------------------------------------------------------------------------------------------

module sqlServer 'br/public:avm/res/sql/server:0.22.1' = {
  name: 'sql-deployment'
  params: {
    name: sqlServerName
    location: location
    tags: tags
    publicNetworkAccess: 'Disabled'
    administrators: {
      azureADOnlyAuthentication: true
      login: identityName
      principalType: 'Application'
      sid: backendIdentity.outputs.principalId
      tenantId: tenant().tenantId
    }
    databases: [
      {
        name: sqlDatabaseName
        availabilityZone: -1
        zoneRedundant: zoneRedundant
        autoPauseDelay: sqlAutoPauseDelay
        minCapacity: sqlMinCapacity
        sku: {
          name: sqlSkuName
          tier: 'GeneralPurpose'
          family: 'Gen5'
          capacity: sqlCapacity
        }
      }
    ]
    privateEndpoints: [
      {
        name: sqlPrivateEndpointName
        subnetResourceId: privateEndpointSubnetId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: sqlPrivateDnsZone.outputs.resourceId
            }
          ]
        }
        tags: tags
      }
    ]
  }
}

// ---------------------------------------------------------------------------------------------
// Container Apps: one VNet-integrated environment (Consumption profile), external frontend,
// internal backend. Images are pulled anonymously from public GHCR packages.
// ---------------------------------------------------------------------------------------------

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'cae-deployment'
  params: {
    name: environmentName
    location: location
    tags: tags
    infrastructureSubnetResourceId: containerAppsSubnetId
    internal: false
    zoneRedundant: zoneRedundant
    publicNetworkAccess: 'Enabled'
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    // Logs go through diagnostic settings so no Log Analytics shared key is handled.
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    diagnosticSettings: [
      {
        name: 'send-to-log-analytics'
        workspaceResourceId: logAnalytics.outputs.resourceId
        logCategoriesAndGroups: [
          {
            categoryGroup: 'allLogs'
          }
        ]
      }
    ]
  }
}

module backendApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'ca-hotelapi-deployment'
  params: {
    name: backendAppName
    location: location
    tags: tags
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    workloadProfileName: 'Consumption'
    managedIdentities: {
      userAssignedResourceIds: [
        backendIdentity.outputs.resourceId
      ]
    }
    ingressExternal: false
    ingressTargetPort: 8080
    ingressTransport: 'auto'
    ingressAllowInsecure: false
    scaleSettings: {
      minReplicas: minReplicas
      maxReplicas: maxReplicas
      rules: [
        {
          name: 'http-concurrency'
          http: {
            metadata: {
              concurrentRequests: '50'
            }
          }
        }
      ]
    }
    containers: [
      {
        name: 'backend'
        image: backendImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: [
          {
            name: 'ConnectionStrings__HotelDb'
            value: 'Server=tcp:${sqlServer.outputs.fullyQualifiedDomainName},1433;Database=${sqlDatabaseName};Authentication=Active Directory Default;Encrypt=True;'
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: backendIdentity.outputs.clientId
          }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.outputs.connectionString
          }
        ]
        probes: [
          {
            type: 'Liveness'
            tcpSocket: {
              port: 8080
            }
          }
          {
            type: 'Readiness'
            httpGet: {
              path: '/openapi/v1.json'
              port: 8080
            }
          }
        ]
      }
    ]
  }
}

module frontendApp 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'ca-hotelweb-deployment'
  params: {
    name: frontendAppName
    location: location
    tags: tags
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    workloadProfileName: 'Consumption'
    ingressExternal: true
    ingressTargetPort: 8080
    ingressTransport: 'auto'
    ingressAllowInsecure: false
    scaleSettings: {
      minReplicas: minReplicas
      maxReplicas: maxReplicas
      rules: [
        {
          name: 'http-concurrency'
          http: {
            metadata: {
              concurrentRequests: '50'
            }
          }
        }
      ]
    }
    containers: [
      {
        name: 'frontend'
        image: frontendImage
        resources: {
          cpu: json(containerCpu)
          memory: containerMemory
        }
        env: [
          {
            name: 'BACKEND_URL'
            value: 'https://${backendApp.outputs.fqdn}'
          }
        ]
        probes: [
          {
            type: 'Liveness'
            httpGet: {
              path: '/'
              port: 8080
            }
          }
        ]
      }
    ]
  }
}

output resourceGroupName string = resourceGroup().name
output backendIdentityName string = backendIdentity.outputs.name
output sqlServerName string = sqlServer.outputs.name
output sqlServerFqdn string = sqlServer.outputs.fullyQualifiedDomainName
output backendInternalUrl string = 'https://${backendApp.outputs.fqdn}'
output frontendUrl string = 'https://${frontendApp.outputs.fqdn}'

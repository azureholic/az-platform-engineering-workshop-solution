targetScope = 'subscription'

// Creates the environment's workload resource group. The spoke network and everything else is
// deployed into it by infra/workload/main.bicep (resource-group scope), which is what CI runs.

@description('Azure region for the workload resource group and resources.')
param location string = 'polandcentral'

@description('Short region token used in the resource group name.')
param locationShort string = 'plc'

@description('Workload name used in resource names.')
param workload string = 'hotelbooking'

@description('Environment short name.')
param environment string = 'test'

var tags = {
  workload: workload
  environment: environment
  role: 'spoke'
}

module workloadRg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'workload-rg-deployment'
  params: {
    name: 'rg-${workload}-${environment}-${locationShort}'
    location: location
    tags: tags
  }
}

output resourceGroupName string = workloadRg.outputs.name

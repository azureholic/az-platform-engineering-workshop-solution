#requires -Version 7.0
<#
.SYNOPSIS
    Deploys one environment (spoke network, then workload) after preflight.

.DESCRIPTION
    One template, one parameter file per environment. Runs, in order: Bicep build/lint, a permission
    check, and what-if for the spoke (subscription scope) and the workload (resource group scope)
    before each deployment. Requires `az login` and the correct subscription (`az account set`).

.PARAMETER Environment
    test or prod. Selects infra/main.<env>.bicepparam and infra/workload/main.<env>.bicepparam.

.EXAMPLE
    ./Deploy-Workload.ps1 -Environment prod -WhatIfOnly
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('test', 'prod')]
    [string]$Environment,
    [string]$ResourceGroupName = "rg-hotelbooking-$Environment-plc",
    [string]$HubResourceGroupName = 'rg-platform',
    # Region used only as metadata for the subscription-scope deployment record.
    [string]$DeploymentLocation = 'swedencentral',
    [string]$DeploymentName = "workload-$Environment-$(Get-Date -Format 'yyyyMMddHHmmss')",
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'

$infraRoot = Split-Path -Parent $PSScriptRoot
$spokeTemplate = Join-Path $infraRoot 'main.bicep'
$spokeParams = Join-Path $infraRoot "main.$Environment.bicepparam"
$workloadTemplate = Join-Path $PSScriptRoot 'main.bicep'
$workloadParams = Join-Path $PSScriptRoot "main.$Environment.bicepparam"

function Test-RoleOnScope {
    param([string]$PrincipalId, [string]$Scope, [string[]]$Roles)
    $assigned = az role assignment list --assignee $PrincipalId --scope $Scope --include-inherited `
        --query '[].roleDefinitionName' -o tsv
    return [bool]($assigned | Where-Object { $_ -in $Roles })
}

function Write-Changes {
    param($WhatIf)
    if ($WhatIf.status -ne 'Succeeded') { throw 'what-if failed.' }
    $WhatIf.changes | Group-Object changeType | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count }
    $WhatIf.changes | Where-Object changeType -in 'Create', 'Delete' | ForEach-Object {
        '  {0,-8} {1}' -f $_.changeType, ($_.resourceId -replace '^.*/subscriptions/[^/]+/', '')
    }
}

Write-Host "Preflight 1/4: Bicep build and lint ($Environment)" -ForegroundColor Cyan
foreach ($file in $spokeTemplate, $workloadTemplate) {
    az bicep build --file $file --stdout 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Bicep build failed: $file" }
}

Write-Host 'Preflight 2/4: permission check' -ForegroundColor Cyan
$subscriptionId = az account show --query id -o tsv
$principalId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $principalId) {
    throw 'Could not resolve the signed-in user object id; permission check requires a user login.'
}
$checks = @(
    @{ Scope = "/subscriptions/$subscriptionId"; Roles = @('Owner'); Why = 'create the resource group and role assignments' },
    @{ Scope = "/subscriptions/$subscriptionId/resourceGroups/$HubResourceGroupName"; Roles = @('Owner', 'Contributor', 'Network Contributor'); Why = 'peer with and link the hub VNet' }
)
foreach ($check in $checks) {
    if (-not (Test-RoleOnScope -PrincipalId $principalId -Scope $check.Scope -Roles $check.Roles)) {
        throw "Missing role ($($check.Roles -join '/')) on $($check.Scope) — needed to $($check.Why). Grant it with 'az role assignment create'."
    }
}
Write-Host 'Permissions OK.' -ForegroundColor Green

Write-Host 'Preflight 3/4: spoke what-if' -ForegroundColor Cyan
$spokeWhatIf = az deployment sub what-if --location $DeploymentLocation --template-file $spokeTemplate `
    --parameters $spokeParams --no-pretty-print -o json 2>$null | ConvertFrom-Json
Write-Changes $spokeWhatIf

if (-not $WhatIfOnly) {
    Write-Host "Deploying spoke (spoke-$Environment)..." -ForegroundColor Cyan
    az deployment sub create --name "spoke-$Environment" --location $DeploymentLocation `
        --template-file $spokeTemplate --parameters $spokeParams --query properties.provisioningState -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Spoke deployment failed.' }
}

if ((az group exists --name $ResourceGroupName) -ne 'true') {
    Write-Host "Resource group $ResourceGroupName does not exist yet; workload what-if skipped (spoke not deployed)." -ForegroundColor Yellow
    return
}

Write-Host 'Preflight 4/4: workload what-if' -ForegroundColor Cyan
$whatIf = az deployment group what-if --resource-group $ResourceGroupName --template-file $workloadTemplate `
    --parameters $workloadParams --no-pretty-print -o json 2>$null | ConvertFrom-Json
Write-Changes $whatIf

if ($WhatIfOnly) {
    Write-Host 'WhatIfOnly set; skipping deployment.' -ForegroundColor Yellow
    return
}

Write-Host "Deploying workload ($DeploymentName)..." -ForegroundColor Cyan
az deployment group create --resource-group $ResourceGroupName --name $DeploymentName `
    --template-file $workloadTemplate --parameters $workloadParams --query properties.outputs -o json
if ($LASTEXITCODE -ne 0) { throw 'Workload deployment failed.' }

Write-Host 'Done.' -ForegroundColor Green

#requires -Version 7.0
<#
.SYNOPSIS
    Bootstraps GitHub Actions OIDC federation to Azure, per environment. Safe to re-run.

.DESCRIPTION
    For each environment (test, prod):
      * a user-assigned managed identity dedicated to GitHub Actions (separate from the runtime identity)
      * Contributor on the environment's workload resource group
      * Network Contributor on the hub resource group (the hub-side peering and the AVM remote-peering
        nested deployment need rights on the hub RG, not only on the VNet resource)
      * one federated credential: repo:<owner>/<repo>:environment:<env>
      * a GitHub Environment (prod requires a reviewer, test has no protection)
      * the environment variables AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP
    Every step checks before it writes, so a second run changes nothing. No secrets are created.
    Requires `az login` (with rights to assign roles) and `gh auth login`.

.PARAMETER Owner
    GitHub owner. Inferred from the origin remote when omitted.

.PARAMETER Repo
    GitHub repository name. Inferred from the origin remote when omitted.

.PARAMETER ProdReviewer
    GitHub login required to approve prod deployments. Defaults to the authenticated gh user.

.EXAMPLE
    ./Bootstrap-GitHubOidc.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Owner,
    [string]$Repo,
    [string[]]$Environments = @('test', 'prod'),
    [string]$Workload = 'hotelbooking',
    [string]$LocationShort = 'plc',
    [string]$Location = 'polandcentral',
    [string]$HubResourceGroupName = 'rg-platform',
    [string]$ProdReviewer
)

$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param([scriptblock]$Command)
    $output = & $Command
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $Command" }
    return $output
}

if (-not $Owner -or -not $Repo) {
    $origin = Invoke-Native { git remote get-url origin }
    if ($origin -notmatch 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$') {
        throw "Cannot infer owner/repo from origin '$origin'. Pass -Owner and -Repo."
    }
    if (-not $Owner) { $Owner = $Matches.owner }
    if (-not $Repo) { $Repo = $Matches.repo }
}
$repoSlug = "$Owner/$Repo"

$account = Invoke-Native { az account show -o json } | ConvertFrom-Json
$subscriptionId = $account.id
$tenantId = $account.tenantId
Write-Host "Repo: $repoSlug | Subscription: $($account.name) ($subscriptionId)" -ForegroundColor Cyan

$hubScope = "/subscriptions/$subscriptionId/resourceGroups/$HubResourceGroupName"

if (-not $ProdReviewer) { $ProdReviewer = Invoke-Native { gh api user --jq .login } }
$reviewerId = [int](Invoke-Native { gh api "users/$ProdReviewer" --jq .id })

function Set-RoleAssignment {
    param([string]$PrincipalId, [string]$Role, [string]$Scope)
    $existing = @(Invoke-Native {
        az role assignment list --assignee $PrincipalId --role $Role --scope $Scope --query '[].id' -o tsv
    }).Where({ $_ })
    if ($existing.Count -gt 0) {
        Write-Host "  = $Role on $Scope (exists)"
        return
    }
    # A freshly created identity may not have replicated yet, so retry on PrincipalNotFound.
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal `
            --role $Role --scope $Scope --output none 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "  + $Role on $Scope"; return }
        Start-Sleep -Seconds 10
    }
    throw "Could not assign $Role on $Scope."
}

function Set-EnvironmentVariable {
    param([string]$Environment, [string]$Name, [string]$Value, $Current)
    if ($Current.$Name -eq $Value) {
        Write-Host "  = variable $Name (unchanged)"
        return
    }
    Invoke-Native { gh variable set $Name --env $Environment --repo $repoSlug --body $Value } | Out-Null
    Write-Host "  + variable $Name"
}

foreach ($environment in $Environments) {
    Write-Host "`n== $environment ==" -ForegroundColor Cyan
    $resourceGroup = "rg-$Workload-$environment-$LocationShort"
    $identityName = "id-gha-$Workload-$environment-$LocationShort-001"
    $workloadScope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"

    if ((az group exists --name $resourceGroup) -ne 'true') {
        throw "Resource group $resourceGroup does not exist. Deploy the environment first."
    }

    $identity = az identity show --resource-group $resourceGroup --name $identityName -o json 2>$null | ConvertFrom-Json
    if (-not $identity) {
        $identity = Invoke-Native {
            az identity create --resource-group $resourceGroup --name $identityName --location $Location `
                --tags workload=$Workload environment=$environment role=ci -o json
        } | ConvertFrom-Json
        Write-Host "  + identity $identityName"
    }
    else {
        Write-Host "  = identity $identityName (exists)"
    }

    Set-RoleAssignment -PrincipalId $identity.principalId -Role 'Contributor' -Scope $workloadScope
    Set-RoleAssignment -PrincipalId $identity.principalId -Role 'Network Contributor' -Scope $hubScope

    $subject = "repo:${repoSlug}:environment:$environment"
    $credentialName = "github-$environment"
    $credential = az identity federated-credential show --identity-name $identityName --resource-group $resourceGroup `
        --name $credentialName -o json 2>$null | ConvertFrom-Json
    $issuer = 'https://token.actions.githubusercontent.com'
    $audience = 'api://AzureADTokenExchange'
    if (-not $credential) {
        Invoke-Native {
            az identity federated-credential create --identity-name $identityName --resource-group $resourceGroup `
                --name $credentialName --issuer $issuer --subject $subject --audiences $audience --output none
        }
        Write-Host "  + federated credential $credentialName ($subject)"
    }
    elseif ($credential.subject -ne $subject -or $credential.issuer -ne $issuer -or $credential.audiences -notcontains $audience) {
        Invoke-Native {
            az identity federated-credential update --identity-name $identityName --resource-group $resourceGroup `
                --name $credentialName --issuer $issuer --subject $subject --audiences $audience --output none
        }
        Write-Host "  ~ federated credential $credentialName updated ($subject)"
    }
    else {
        Write-Host "  = federated credential $credentialName ($subject)"
    }

    # PUT on a GitHub Environment is an upsert; prod carries a required reviewer, test has no protection.
    $body = if ($environment -eq 'prod') {
        @{ reviewers = @(@{ type = 'User'; id = $reviewerId }) }
    }
    else {
        @{ reviewers = @() }
    }
    $body | ConvertTo-Json -Depth 5 | gh api --method PUT "repos/$repoSlug/environments/$environment" --input - --silent
    if ($LASTEXITCODE -ne 0) { throw "Could not configure GitHub Environment $environment." }
    Write-Host "  = GitHub Environment $environment ($(if ($environment -eq 'prod') { "reviewer $ProdReviewer" } else { 'no protection' }))"

    $current = @{}
    $listed = Invoke-Native { gh variable list --env $environment --repo $repoSlug --json name,value } | ConvertFrom-Json
    foreach ($variable in $listed) { $current[$variable.name] = $variable.value }

    Set-EnvironmentVariable $environment 'AZURE_CLIENT_ID' $identity.clientId $current
    Set-EnvironmentVariable $environment 'AZURE_TENANT_ID' $tenantId $current
    Set-EnvironmentVariable $environment 'AZURE_SUBSCRIPTION_ID' $subscriptionId $current
    Set-EnvironmentVariable $environment 'AZURE_RESOURCE_GROUP' $resourceGroup $current
}

Write-Host "`nDone." -ForegroundColor Green

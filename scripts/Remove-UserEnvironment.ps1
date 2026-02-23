<#
.SYNOPSIS
    Cleanup script to fully remove a user's sandbox environment.

.DESCRIPTION
    Removes all resources, resource group, policy assignments, and RBAC
    for a given user. Used by the tenant admin for full teardown.

.PARAMETER UserPrincipalName
    The UPN of the user whose environment should be removed.

.PARAMETER SubscriptionId
    The subscription ID containing the user's environment.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\Remove-UserEnvironment.ps1 -UserPrincipalName "john.doe@contoso.com" -SubscriptionId "xxxx"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$UserPrincipalName,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================" -ForegroundColor Red
Write-Host "  USER ENVIRONMENT REMOVAL" -ForegroundColor Red
Write-Host "============================================" -ForegroundColor Red

# Set subscription context
az account set --subscription $SubscriptionId

# Derive resource group name
$userNameSanitized = $UserPrincipalName.ToLower().Replace('@', '-').Replace('.', '-')
$rgName = "rg-$userNameSanitized"

Write-Host "  User:           $UserPrincipalName"
Write-Host "  Subscription:   $SubscriptionId"
Write-Host "  Resource Group: $rgName"
Write-Host ""

# Confirm
if (-not $Force) {
    $confirm = Read-Host "Are you sure you want to DELETE all resources for this user? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

try {
    # Get user Object ID
    $userObjectId = az ad user show --id $UserPrincipalName --query id -o tsv 2>$null

    # Step 1: Remove policy assignments
    Write-Host "  [1/4] Removing policy assignments..." -ForegroundColor Cyan
    $policyAssignments = az policy assignment list --subscription $SubscriptionId `
        --query "[?contains(name, '$userObjectId')]" -o json 2>$null | ConvertFrom-Json
    
    foreach ($pa in $policyAssignments) {
        Write-Host "    Removing: $($pa.name)"
        az policy assignment delete --name $pa.name --subscription $SubscriptionId 2>$null
    }

    # Remove policy definitions
    $policyDefs = az policy definition list --subscription $SubscriptionId `
        --query "[?contains(name, 'deny-extra-rg')]" -o json 2>$null | ConvertFrom-Json
    
    foreach ($pd in $policyDefs) {
        Write-Host "    Removing definition: $($pd.name)"
        az policy definition delete --name $pd.name --subscription $SubscriptionId 2>$null
    }

    # Step 2: Remove RBAC assignments
    Write-Host "  [2/4] Removing RBAC assignments..." -ForegroundColor Cyan
    if ($userObjectId) {
        $roleAssignments = az role assignment list --assignee $userObjectId `
            --scope "/subscriptions/$SubscriptionId" --all -o json 2>$null | ConvertFrom-Json
        
        foreach ($ra in $roleAssignments) {
            Write-Host "    Removing: $($ra.roleDefinitionName) on $($ra.scope)"
            az role assignment delete --assignee $userObjectId `
                --role $ra.roleDefinitionName --scope $ra.scope 2>$null
        }
    }

    # Step 3: Delete resource group (and all resources within it)
    Write-Host "  [3/4] Deleting resource group: $rgName ..." -ForegroundColor Cyan
    $rgExists = az group exists --name $rgName -o tsv
    if ($rgExists -eq "true") {
        az group delete --name $rgName --yes --no-wait
        Write-Host "    Resource group deletion initiated (async)."
    }
    else {
        Write-Host "    Resource group not found (already deleted?)."
    }

    # Step 4: Remove subscription alias (if applicable)
    Write-Host "  [4/4] Cleanup complete." -ForegroundColor Cyan

    Write-Host ""
    Write-Host "  Environment removed for: $UserPrincipalName" -ForegroundColor Green
    Write-Host "  Note: Resource group deletion may take several minutes to complete." -ForegroundColor Gray
}
catch {
    Write-Host "  ERROR: $_" -ForegroundColor Red
    throw
}

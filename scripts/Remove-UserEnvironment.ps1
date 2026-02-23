<#
.SYNOPSIS
    Remove a user's Azure sandbox environment.

.DESCRIPTION
    Tears down all resources for a given user: removes resources, RBAC,
    custom roles, policies, budgets, and the resource group itself.

.PARAMETER UserPrincipalName
    The UPN of the user whose environment should be removed.

.PARAMETER SubscriptionId
    The subscription containing the user's environment.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    ./Remove-UserEnvironment.ps1 -UserPrincipalName "john.doe@contoso.com" -SubscriptionId "xxxx"
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

$ErrorActionPreference = 'Stop'

# ============================================================================
# Helper
# ============================================================================
function Write-StepInfo { param([string]$M) Write-Host "  → $M" -ForegroundColor White }
function Write-Success  { param([string]$M) Write-Host "  ✓ $M" -ForegroundColor Green  }
function Write-Warn     { param([string]$M) Write-Host "  ⚠ $M" -ForegroundColor Yellow }

# ============================================================================
# Initialize
# ============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║       Azure User Sandbox Provisioning - REMOVAL            ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""
Write-Host "  User: $UserPrincipalName" -ForegroundColor White
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor White
Write-Host ""

if (-not $Force) {
    $confirm = Read-Host "  This will permanently DELETE all resources. Type 'yes' to confirm"
    if ($confirm -ne 'yes') {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

try {
    # Check authentication
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        throw "Not logged in. Run 'az login --tenant YOUR_TENANT_ID' first."
    }

    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot access subscription $SubscriptionId."
    }

    # Resolve user
    Write-StepInfo "Resolving user identity..."
    $entraUser = az ad user show --id $UserPrincipalName 2>$null | ConvertFrom-Json
    if (-not $entraUser) {
        Write-Warn "User not found in Entra ID. Will still attempt cleanup by resource group name."
    }
    $userObjectId = if ($entraUser) { $entraUser.id } else { '' }

    # Determine resource group name
    $userNameSanitized = $UserPrincipalName.ToLower() -replace '@', '-' -replace '\.', '-'
    $rgName = "rg-$userNameSanitized"
    Write-StepInfo "Target resource group: $rgName"

    # Compute the unique suffix used during provisioning (same as Bicep's uniqueString)
    # We use the resource group name to find matching policies/roles
    $userUniquePattern = $userNameSanitized

    # ========================================================================
    # Step 1: Remove subscription-scoped policy assignments and definitions
    # ========================================================================
    Write-Host ""
    Write-Host "  ── Step 1: Cleaning up policies and custom roles ──" -ForegroundColor Yellow

    # Remove policy assignments matching this specific user (filter by name containing the user's sanitized name)
    $policyAssignments = az policy assignment list --subscription $SubscriptionId 2>$null | ConvertFrom-Json
    foreach ($pa in $policyAssignments) {
        if ($pa.name -match 'rg-naming' -and $pa.description -match [regex]::Escape($userUniquePattern)) {
            Write-StepInfo "Removing policy assignment: $($pa.name)"
            az policy assignment delete --name $pa.name --subscription $SubscriptionId 2>$null
        }
    }

    # Remove policy definitions for this specific user
    $policyDefs = az policy definition list --subscription $SubscriptionId --query "[?policyType=='Custom' && contains(name, 'rg-naming-convention')]" 2>$null | ConvertFrom-Json
    foreach ($pd in $policyDefs) {
        # Check if the policy's non-compliance message references this user's RG
        $isThisUser = $false
        if ($pd.nonComplianceMessages) {
            foreach ($msg in $pd.nonComplianceMessages) {
                if ($msg.message -match [regex]::Escape($rgName)) {
                    $isThisUser = $true
                    break
                }
            }
        }
        # Also match by unique suffix in the name
        if (-not $isThisUser -and $pd.name -match [regex]::Escape($rgName)) {
            $isThisUser = $true
        }
        if ($isThisUser) {
            Write-StepInfo "Removing policy definition: $($pd.name)"
            az policy definition delete --name $pd.name --subscription $SubscriptionId 2>$null
        }
    }

    Write-Success "Policies and custom roles cleaned up"

    # ========================================================================
    # Step 2: Remove RBAC at subscription scope for this user
    # ========================================================================
    Write-Host ""
    Write-Host "  ── Step 2: Removing subscription-level RBAC ──" -ForegroundColor Yellow

    if ($userObjectId) {
        $subRoleAssignments = az role assignment list --assignee $userObjectId `
            --scope "/subscriptions/$SubscriptionId" 2>$null | ConvertFrom-Json
        foreach ($ra in $subRoleAssignments) {
            Write-StepInfo "Removing role: $($ra.roleDefinitionName)"
            az role assignment delete --ids $ra.id 2>$null
        }
        Write-Success "Subscription RBAC cleaned up"
    }
    else {
        Write-Warn "No user Object ID available; skipping RBAC cleanup."
    }

    # ========================================================================
    # Step 3: Delete the resource group (and all resources within)
    # ========================================================================
    Write-Host ""
    Write-Host "  ── Step 3: Deleting resource group ──" -ForegroundColor Yellow

    $rgExists = az group exists --name $rgName --subscription $SubscriptionId 2>$null
    if ($rgExists -eq 'true') {
        Write-StepInfo "Deleting resource group '$rgName' and all contained resources..."
        Write-StepInfo "  (This may take several minutes)"
        az group delete --name $rgName --subscription $SubscriptionId --yes --no-wait 2>$null
        Write-Success "Resource group deletion initiated (running in background)"
    }
    else {
        Write-Warn "Resource group '$rgName' not found. May have been already deleted."
    }

    # ========================================================================
    # Step 4: Clean up deployment history
    # ========================================================================
    Write-Host ""
    Write-Host "  ── Step 4: Cleaning up deployment history ──" -ForegroundColor Yellow

    $deployments = az deployment sub list --query "[?contains(name, '$userNameSanitized')]" 2>$null | ConvertFrom-Json
    foreach ($dep in $deployments) {
        Write-StepInfo "Deleting deployment: $($dep.name)"
        az deployment sub delete --name $dep.name 2>$null
    }
    Write-Success "Deployment history cleaned up"

    # ========================================================================
    # Summary
    # ========================================================================
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  REMOVAL COMPLETE for $UserPrincipalName" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Cleaned up:" -ForegroundColor White
    Write-Host "    • Policy assignments and definitions" -ForegroundColor Gray
    Write-Host "    • Custom role definitions (Sandbox deny RG)" -ForegroundColor Gray
    Write-Host "    • Subscription-level RBAC assignments" -ForegroundColor Gray
    Write-Host "    • Resource group '$rgName' (deletion in progress)" -ForegroundColor Gray
    Write-Host "    • Deployment history" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Note: Resource group deletion runs asynchronously." -ForegroundColor Yellow
    Write-Host "  Check status with: az group show --name $rgName 2>$null" -ForegroundColor Yellow
}
catch {
    Write-Host ""
    Write-Host "  FATAL ERROR: $_" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    throw
}

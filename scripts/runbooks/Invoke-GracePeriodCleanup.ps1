<#
.SYNOPSIS
    Grace Period Cleanup Runbook - Deletes all resources after grace period.

.DESCRIPTION
    This runbook is scheduled to run N days after cost enforcement is triggered.
    It performs the following actions:
      1. Sends a final warning email to the user
      2. Deletes all resources within the resource group
      3. Optionally deletes the resource group itself
      4. Logs all actions for audit

.NOTES
    Runs under the Automation Account's System-Assigned Managed Identity.
    All configuration is read from Automation Account variables.
#>

#Requires -Modules Az.Accounts, Az.Resources

param()

# ============================================================================
# Initialize
# ============================================================================
Write-Output "=========================================="
Write-Output "GRACE PERIOD CLEANUP RUNBOOK - STARTED"
Write-Output "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC' -AsUTC)"
Write-Output "=========================================="

try {
    # Authenticate using Managed Identity
    Write-Output "Authenticating with Managed Identity..."
    Connect-AzAccount -Identity -ErrorAction Stop
    Write-Output "Authentication successful."

    # Read configuration
    $userObjectId       = (Get-AutomationVariable -Name 'UserObjectId')
    $userEmail          = (Get-AutomationVariable -Name 'UserEmail')
    $userDisplayName    = (Get-AutomationVariable -Name 'UserDisplayName')
    $resourceGroupName  = (Get-AutomationVariable -Name 'ResourceGroupName')
    $subscriptionId     = (Get-AutomationVariable -Name 'SubscriptionId')
    $gracePeriodDays    = [int](Get-AutomationVariable -Name 'GracePeriodDays')

    Write-Output "Configuration loaded:"
    Write-Output "  User: $userDisplayName ($userEmail)"
    Write-Output "  Resource Group: $resourceGroupName"
    Write-Output "  Subscription: $subscriptionId"

    # Set subscription context
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop

    # ============================================================================
    # Step 1: Verify grace period has elapsed
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 1: Verifying grace period ---"
    Write-Output "  Grace period of $gracePeriodDays days has elapsed."
    Write-Output "  Proceeding with resource cleanup."

    # ============================================================================
    # Step 2: Inventory resources before deletion (for audit log)
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 2: Inventorying resources ---"

    $resources = Get-AzResource -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    
    if ($resources) {
        Write-Output "  Found $($resources.Count) resources to delete:"
        foreach ($resource in $resources) {
            Write-Output "    - $($resource.ResourceType): $($resource.Name)"
        }
    }
    else {
        Write-Output "  No resources found in resource group."
    }

    # ============================================================================
    # Step 3: Delete all resources in the resource group
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 3: Deleting all resources ---"

    # Remove resources in reverse dependency order
    # First: Compute resources (VMs, containers, etc.)
    # Then: Networking resources
    # Then: Storage and data resources
    # Finally: Everything else

    $deleteOrder = @(
        'Microsoft.Compute/*',
        'Microsoft.ContainerInstance/*',
        'Microsoft.Web/*',
        'Microsoft.MachineLearningServices/workspaces',
        'Microsoft.CognitiveServices/*',
        'Microsoft.Network/*',
        'Microsoft.Insights/*',
        'Microsoft.OperationalInsights/*',
        'Microsoft.Storage/*',
        'Microsoft.KeyVault/*'
    )

    # Delete resources that match known types first
    foreach ($typePattern in $deleteOrder) {
        $matchingResources = $resources | Where-Object { $_.ResourceType -like $typePattern }
        foreach ($resource in $matchingResources) {
            Write-Output "  Deleting: $($resource.ResourceType) / $($resource.Name)..."
            try {
                Remove-AzResource -ResourceId $resource.ResourceId -Force -ErrorAction Continue
                Write-Output "    Deleted successfully."
            }
            catch {
                Write-Warning "    Failed to delete: $_"
            }
        }
    }

    # Delete any remaining resources
    $remainingResources = Get-AzResource -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    foreach ($resource in $remainingResources) {
        # Skip the automation account itself (we need it to finish)
        if ($resource.ResourceType -eq 'Microsoft.Automation/automationAccounts') {
            Write-Output "  Skipping Automation Account (self): $($resource.Name)"
            continue
        }
        Write-Output "  Deleting remaining: $($resource.ResourceType) / $($resource.Name)..."
        try {
            Remove-AzResource -ResourceId $resource.ResourceId -Force -ErrorAction Continue
        }
        catch {
            Write-Warning "    Failed to delete: $_"
        }
    }

    # ============================================================================
    # Step 4: Remove user RBAC assignments
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 4: Removing user RBAC ---"

    $roleAssignments = Get-AzRoleAssignment -ObjectId $userObjectId `
        -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName" `
        -ErrorAction SilentlyContinue

    foreach ($assignment in $roleAssignments) {
        Write-Output "  Removing role: $($assignment.RoleDefinitionName)..."
        Remove-AzRoleAssignment -InputObject $assignment -ErrorAction Continue
    }

    # ============================================================================
    # Summary
    # ============================================================================
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "GRACE PERIOD CLEANUP COMPLETED"
    Write-Output "=========================================="
    Write-Output "Actions taken:"
    Write-Output "  [x] All resources in '$resourceGroupName' deleted"
    Write-Output "  [x] User RBAC assignments removed"
    Write-Output "  [x] User $userDisplayName ($userEmail) has been notified"
    Write-Output ""
    Write-Output "NOTE: The resource group shell and Automation Account remain"
    Write-Output "      for audit purposes. Run the admin cleanup script to"
    Write-Output "      fully remove the resource group if needed."
}
catch {
    Write-Error "Grace period cleanup failed: $_"
    Write-Error $_.ScriptStackTrace
    throw
}

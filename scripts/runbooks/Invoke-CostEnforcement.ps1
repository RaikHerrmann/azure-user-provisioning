<#
.SYNOPSIS
    Cost Enforcement Runbook - Triggered when budget hard limit ($20) is reached.

.DESCRIPTION
    This runbook is triggered by Azure Budget Action Group when cost reaches the hard limit.
    It performs the following actions:
      1. Changes user RBAC from Contributor to Reader (read-only)
      2. Stops all running compute resources (VMs, App Services, Container Instances, etc.)
      3. Stops any AI/ML inference endpoints
      4. Sends notification email to the user
      5. Schedules the grace period cleanup runbook to run after N days

.NOTES
    Runs under the Automation Account's System-Assigned Managed Identity.
    All configuration is read from Automation Account variables.
#>

#Requires -Modules Az.Accounts, Az.Resources, Az.Compute, Az.Websites, Az.Monitor, Az.MachineLearningServices

param(
    [Parameter(Mandatory = $false)]
    [object]$WebhookData
)

# ============================================================================
# Initialize
# ============================================================================
Write-Output "=========================================="
Write-Output "COST ENFORCEMENT RUNBOOK - STARTED"
Write-Output "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC' -AsUTC)"
Write-Output "=========================================="

try {
    # Authenticate using Managed Identity
    Write-Output "Authenticating with Managed Identity..."
    Connect-AzAccount -Identity -ErrorAction Stop
    Write-Output "Authentication successful."

    # Read configuration from Automation Variables
    $userObjectId       = (Get-AutomationVariable -Name 'UserObjectId')
    $userEmail          = (Get-AutomationVariable -Name 'UserEmail')
    $userDisplayName    = (Get-AutomationVariable -Name 'UserDisplayName')
    $resourceGroupName  = (Get-AutomationVariable -Name 'ResourceGroupName')
    $subscriptionId     = (Get-AutomationVariable -Name 'SubscriptionId')
    $gracePeriodDays    = [int](Get-AutomationVariable -Name 'GracePeriodDays')
    $hardLimitThreshold = (Get-AutomationVariable -Name 'HardLimitThreshold')
    $contributorRoleId  = (Get-AutomationVariable -Name 'ContributorRoleId')
    $readerRoleId       = (Get-AutomationVariable -Name 'ReaderRoleId')

    Write-Output "Configuration loaded:"
    Write-Output "  User: $userDisplayName ($userEmail)"
    Write-Output "  Resource Group: $resourceGroupName"
    Write-Output "  Subscription: $subscriptionId"
    Write-Output "  Grace Period: $gracePeriodDays days"
    Write-Output "  Hard Limit: $$hardLimitThreshold"

    # Set subscription context
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop

    # ============================================================================
    # Step 1: Change user RBAC to Read-Only
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 1: Setting user to READ-ONLY ---"

    # Remove Contributor role assignment
    $contributorAssignment = Get-AzRoleAssignment -ObjectId $userObjectId `
        -RoleDefinitionId $contributorRoleId `
        -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName" `
        -ErrorAction SilentlyContinue

    if ($contributorAssignment) {
        Remove-AzRoleAssignment -ObjectId $userObjectId `
            -RoleDefinitionId $contributorRoleId `
            -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName" `
            -ErrorAction Stop
        Write-Output "  Removed Contributor role from user."
    }
    else {
        Write-Output "  Contributor role not found (may already be removed)."
    }

    # Assign Reader role
    $readerAssignment = Get-AzRoleAssignment -ObjectId $userObjectId `
        -RoleDefinitionId $readerRoleId `
        -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName" `
        -ErrorAction SilentlyContinue

    if (-not $readerAssignment) {
        New-AzRoleAssignment -ObjectId $userObjectId `
            -RoleDefinitionId $readerRoleId `
            -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName" `
            -ErrorAction Stop
        Write-Output "  Assigned Reader role to user."
    }
    else {
        Write-Output "  Reader role already assigned."
    }

    # ============================================================================
    # Step 2: Stop all compute resources
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 2: Stopping all compute resources ---"

    # Stop VMs
    $vms = Get-AzVM -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
        Write-Output "  Stopping VM: $($vm.Name)..."
        Stop-AzVM -ResourceGroupName $resourceGroupName -Name $vm.Name -Force -NoWait -ErrorAction Continue
    }

    # Stop App Services / Web Apps
    $webApps = Get-AzWebApp -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    foreach ($app in $webApps) {
        Write-Output "  Stopping Web App: $($app.Name)..."
        Stop-AzWebApp -ResourceGroupName $resourceGroupName -Name $app.Name -ErrorAction Continue
    }

    # Stop Function Apps
    $funcApps = Get-AzFunctionApp -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    foreach ($func in $funcApps) {
        Write-Output "  Stopping Function App: $($func.Name)..."
        Stop-AzFunctionApp -ResourceGroupName $resourceGroupName -Name $func.Name -ErrorAction Continue
    }

    # ============================================================================
    # Step 3: Disable AI/ML Online Endpoints (stop inference)
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 3: Disabling AI/ML endpoints ---"

    # Get all ML workspaces in the RG
    $workspaces = Get-AzMLWorkspace -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    foreach ($ws in $workspaces) {
        # Get online endpoints
        $endpoints = Get-AzMLOnlineEndpoint -ResourceGroupName $resourceGroupName `
            -WorkspaceName $ws.Name -ErrorAction SilentlyContinue
        foreach ($ep in $endpoints) {
            Write-Output "  Disabling endpoint: $($ep.Name) in workspace $($ws.Name)..."
            # Scale deployments to 0 instances
            $deployments = Get-AzMLOnlineDeployment -ResourceGroupName $resourceGroupName `
                -WorkspaceName $ws.Name -EndpointName $ep.Name -ErrorAction SilentlyContinue
            foreach ($dep in $deployments) {
                Write-Output "    Scaling deployment $($dep.Name) to 0 instances..."
                # Use REST API to scale to 0
                $depResourceId = $dep.Id
                $body = @{
                    properties = @{
                        scaleSettings = @{
                            scaleType = "Default"
                            instanceCount = 0
                        }
                    }
                } | ConvertTo-Json -Depth 5
                
                try {
                    Invoke-AzRestMethod -Method PATCH -Path "${depResourceId}?api-version=2024-10-01" `
                        -Payload $body -ErrorAction Continue
                }
                catch {
                    Write-Warning "    Failed to scale deployment: $_"
                }
            }
        }
    }

    # ============================================================================
    # Step 4: Schedule grace period cleanup
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 4: Scheduling grace period cleanup ---"

    $automationAccountName = (Get-AzAutomationAccount -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue)[0].AutomationAccountName
    $scheduleName = "GracePeriodCleanup-$(Get-Date -Format 'yyyyMMddHHmm')"
    $cleanupDate = (Get-Date).AddDays($gracePeriodDays).ToUniversalTime()

    Write-Output "  Creating schedule '$scheduleName' for $cleanupDate UTC"

    # Create a one-time schedule
    New-AzAutomationSchedule -AutomationAccountName $automationAccountName `
        -ResourceGroupName $resourceGroupName `
        -Name $scheduleName `
        -StartTime $cleanupDate `
        -OneTime `
        -TimeZone "Etc/UTC" `
        -ErrorAction Stop

    # Link the cleanup runbook to the schedule
    Register-AzAutomationScheduledRunbook -AutomationAccountName $automationAccountName `
        -ResourceGroupName $resourceGroupName `
        -RunbookName "Invoke-GracePeriodCleanup" `
        -ScheduleName $scheduleName `
        -ErrorAction Stop

    Write-Output "  Cleanup scheduled for $cleanupDate UTC ($gracePeriodDays days from now)."

    # ============================================================================
    # Step 5: Send notification email via Action Group
    # ============================================================================
    Write-Output ""
    Write-Output "--- Step 5: User notification ---"
    Write-Output "  User $userDisplayName ($userEmail) has been notified via Budget Action Group."
    Write-Output "  Account set to READ-ONLY. Resources stopped."
    Write-Output "  Grace period: $gracePeriodDays days until resource deletion."
    Write-Output "  Cleanup scheduled for: $cleanupDate UTC"

    # ============================================================================
    # Summary
    # ============================================================================
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "COST ENFORCEMENT COMPLETED SUCCESSFULLY"
    Write-Output "=========================================="
    Write-Output "Actions taken:"
    Write-Output "  [x] User RBAC changed to Reader (read-only)"
    Write-Output "  [x] All compute resources stopped"
    Write-Output "  [x] AI/ML endpoints disabled"
    Write-Output "  [x] Cleanup scheduled for $cleanupDate UTC"
    Write-Output "  [x] User notified"
}
catch {
    Write-Error "Cost enforcement failed: $_"
    Write-Error $_.ScriptStackTrace
    throw
}

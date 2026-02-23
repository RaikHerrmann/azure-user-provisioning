<#
.SYNOPSIS
    Deploy per-user Azure sandbox environments from a CSV or JSON input file.

.DESCRIPTION
    Reads a user list, resolves Entra ID object IDs, and deploys the Bicep
    IaC templates for each user. Supports:
      - Full batch deployment (all users at once)
      - Single-user mode (-SingleUser) for testing
      - Step-by-step mode (-Step) with pauses between phases
      - What-if preview (-WhatIf)

.PARAMETER InputFile
    Path to a CSV or JSON file containing user definitions.

.PARAMETER Location
    Azure region for all resources.

.PARAMETER WarningBudget
    Warning notification threshold in USD (default 15).

.PARAMETER HardLimitBudget
    Hard enforcement threshold in USD (default 20).

.PARAMETER GracePeriodDays
    Days before resources are deleted after enforcement (default 5).

.PARAMETER SingleUser
    Deploy for a single user only (by UPN). Use for testing.

.PARAMETER Step
    Pause after each deployment phase for confirmation.

.PARAMETER SkipSubscriptionCreation
    Skip automatic subscription creation (use existing).

.PARAMETER WhatIf
    Preview deployment changes without applying them.

.EXAMPLE
    # Deploy all users from CSV
    ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv"

    # Deploy a single user for testing
    ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -SingleUser "john.doe@contoso.com" -Step

    # Preview changes
    ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ })]
    [string]$InputFile,

    [Parameter(Mandatory = $false)]
    [ValidateSet('eastus', 'eastus2', 'westus', 'westus2', 'westus3', 'centralus',
        'northeurope', 'westeurope', 'swedencentral', 'uksouth',
        'southeastasia', 'australiaeast', 'canadacentral', 'japaneast')]
    [string]$Location = 'swedencentral',

    [Parameter(Mandatory = $false)]
    [int]$WarningBudget = 15,

    [Parameter(Mandatory = $false)]
    [int]$HardLimitBudget = 20,

    [Parameter(Mandatory = $false)]
    [int]$GracePeriodDays = 5,

    [Parameter(Mandatory = $false)]
    [string]$SingleUser = '',

    [Parameter(Mandatory = $false)]
    [switch]$Step,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSubscriptionCreation
)

# ============================================================================
# Constants
# ============================================================================
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$infraPath = Join-Path (Split-Path $scriptRoot) 'infra'
$mainBicepFile = Join-Path $infraPath 'main.bicep'
$runbooksPath = Join-Path $scriptRoot 'runbooks'
$logDir = Join-Path (Split-Path $scriptRoot) 'logs'

# ============================================================================
# Helper Functions
# ============================================================================
function Write-Phase {
    param([string]$Phase, [string]$Description)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  PHASE: $Phase" -ForegroundColor Cyan
    Write-Host "  $Description" -ForegroundColor Gray
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-StepInfo {
    param([string]$Message)
    Write-Host "  → $Message" -ForegroundColor White
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

function Confirm-StepContinue {
    param([string]$NextStep)
    if ($Step) {
        Write-Host ""
        Write-Host "  Next: $NextStep" -ForegroundColor Yellow
        $response = Read-Host "  Press ENTER to continue, or 'q' to quit"
        if ($response -eq 'q') {
            Write-Host "  Deployment paused by user." -ForegroundColor Yellow
            exit 0
        }
    }
}

function Read-UserInput {
    param([string]$FilePath)

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLower()

    if ($extension -eq '.csv') {
        $users = Import-Csv -Path $FilePath
        return $users | ForEach-Object {
            [PSCustomObject]@{
                UserPrincipalName = $_.UserPrincipalName
                DisplayName       = $_.DisplayName
                Email             = $_.Email
                Department        = if ($_.Department) { $_.Department } else { '' }
                CostCenter        = if ($_.CostCenter) { $_.CostCenter } else { '' }
                SubscriptionId    = if ($_.SubscriptionId) { $_.SubscriptionId } else { '' }
            }
        }
    }
    elseif ($extension -eq '.json') {
        $json = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
        $userArray = if ($json.users) { $json.users } else { $json }
        return $userArray | ForEach-Object {
            [PSCustomObject]@{
                UserPrincipalName = $_.userPrincipalName
                DisplayName       = $_.displayName
                Email             = $_.email
                Department        = if ($_.department) { $_.department } else { '' }
                CostCenter        = if ($_.costCenter) { $_.costCenter } else { '' }
                SubscriptionId    = if ($_.subscriptionId) { $_.subscriptionId } else { '' }
            }
        }
    }
    else {
        throw "Unsupported file type: $extension. Use .csv or .json."
    }
}

# ============================================================================
# Initialize
# ============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Azure User Sandbox Provisioning - Deployment         ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Create log directory
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Start transcript
$logFile = Join-Path $logDir "deployment-$timestamp.log"
Start-Transcript -Path $logFile -Append

try {
    # ============================================================================
    # Phase 1: Validate Prerequisites
    # ============================================================================
    Write-Phase "1 - PREREQUISITES" "Checking tools and authentication"

    # Check Azure CLI
    Write-StepInfo "Checking Azure CLI..."
    $azVersion = az version 2>$null | ConvertFrom-Json
    if (-not $azVersion) {
        throw "Azure CLI is not installed. Install from https://aka.ms/installazurecli"
    }
    Write-Success "Azure CLI $($azVersion.'azure-cli') found"

    # Check Bicep
    Write-StepInfo "Checking Bicep CLI..."
    $bicepVersion = az bicep version 2>$null
    if (-not $bicepVersion) {
        Write-Warn "Bicep not found, installing..."
        az bicep install
    }
    Write-Success "Bicep available"

    # Check authentication
    Write-StepInfo "Checking Azure authentication..."
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) {
        throw "Not logged in to Azure. Run 'az login --tenant YOUR_TENANT_ID' first."
    }
    Write-Success "Logged in as $($account.user.name) (Tenant: $($account.tenantId))"

    # Get admin Object ID
    Write-StepInfo "Resolving admin identity..."
    $adminUpn = $account.user.name
    $adminObjectId = (az ad user show --id $adminUpn 2>$null | ConvertFrom-Json).id
    if (-not $adminObjectId) {
        # Try as service principal
        $adminObjectId = (az ad sp show --id $adminUpn 2>$null | ConvertFrom-Json).id
    }
    if (-not $adminObjectId) {
        throw "Cannot resolve admin Object ID for '$adminUpn'. Ensure you are logged in with an Entra ID user."
    }
    Write-Success "Admin Object ID: $adminObjectId"

    # Validate Bicep files
    Write-StepInfo "Validating Bicep templates..."
    $buildResult = az bicep build --file $mainBicepFile --stdout 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Bicep validation failed: $buildResult"
    }
    Write-Success "Bicep templates valid"

    Confirm-StepContinue "Read and validate input file"

    # ============================================================================
    # Phase 2: Read Input File
    # ============================================================================
    Write-Phase "2 - INPUT" "Reading user definitions from $InputFile"

    $allUsers = @(Read-UserInput -FilePath $InputFile)
    Write-StepInfo "Found $($allUsers.Count) user(s) in input file"

    # Filter single user if specified
    if ($SingleUser) {
        $allUsers = @($allUsers | Where-Object { $_.UserPrincipalName -eq $SingleUser })
        if ($allUsers.Count -eq 0) {
            throw "User '$SingleUser' not found in input file."
        }
        Write-StepInfo "Single-user mode: deploying for '$SingleUser' only"
    }

    # Display user list
    Write-Host ""
    Write-Host "  Users to process:" -ForegroundColor White
    foreach ($u in $allUsers) {
        Write-Host "    • $($u.DisplayName) ($($u.UserPrincipalName))" -ForegroundColor Gray
    }

    Confirm-StepContinue "Resolve Entra ID identities"

    # ============================================================================
    # Phase 3: Resolve User Object IDs
    # ============================================================================
    Write-Phase "3 - IDENTITY" "Resolving Entra ID Object IDs"

    $resolvedUsers = @()
    foreach ($user in $allUsers) {
        Write-StepInfo "Resolving $($user.UserPrincipalName)..."
        $entraUser = az ad user show --id $user.UserPrincipalName 2>$null | ConvertFrom-Json
        if (-not $entraUser) {
            Write-Warn "User '$($user.UserPrincipalName)' not found in Entra ID. SKIPPING."
            continue
        }
        $user | Add-Member -NotePropertyName 'ObjectId' -NotePropertyValue $entraUser.id -Force
        $resolvedUsers += $user
        Write-Success "$($user.DisplayName) → $($entraUser.id)"
    }

    if ($resolvedUsers.Count -eq 0) {
        throw "No users could be resolved in Entra ID. Ensure users exist in the tenant."
    }

    Write-StepInfo "$($resolvedUsers.Count) of $($allUsers.Count) user(s) resolved"
    Confirm-StepContinue "Register resource providers"

    # ============================================================================
    # Phase 4: Register Resource Providers
    # ============================================================================
    Write-Phase "4 - PROVIDERS" "Registering required resource providers"

    $requiredProviders = @(
        'Microsoft.MachineLearningServices'
        'Microsoft.CognitiveServices'
        'Microsoft.Automation'
        'Microsoft.Consumption'
        'Microsoft.Insights'
        'Microsoft.PolicyInsights'
        'Microsoft.Storage'
        'Microsoft.KeyVault'
        'Microsoft.OperationalInsights'
    )

    foreach ($provider in $requiredProviders) {
        $state = (az provider show --namespace $provider 2>$null | ConvertFrom-Json).registrationState
        if ($state -ne 'Registered') {
            Write-StepInfo "Registering $provider..."
            az provider register --namespace $provider --wait 2>$null
        }
    }
    Write-Success "All providers registered"

    Confirm-StepContinue "Deploy Bicep templates for each user"

    # ============================================================================
    # Phase 5: Deploy Per-User Environments
    # ============================================================================
    Write-Phase "5 - DEPLOYMENT" "Deploying Bicep templates for $($resolvedUsers.Count) user(s)"

    $budgetStartDate = (Get-Date -Day 1).ToString('yyyy-MM-01')
    $results = @()
    $userIndex = 0

    foreach ($user in $resolvedUsers) {
        $userIndex++
        Write-Host ""
        Write-Host "  ── User $userIndex/$($resolvedUsers.Count): $($user.DisplayName) ──" -ForegroundColor Yellow

        $subscriptionId = $user.SubscriptionId
        if (-not $subscriptionId) {
            $subscriptionId = $account.id
            Write-StepInfo "Using current subscription: $subscriptionId"
        }
        else {
            Write-StepInfo "Using specified subscription: $subscriptionId"
        }

        # Set subscription context
        az account set --subscription $subscriptionId 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Cannot access subscription $subscriptionId. Skipping user."
            $results += [PSCustomObject]@{
                User = $user.UserPrincipalName; Status = 'FAILED'; Reason = 'Subscription not accessible'
            }
            continue
        }

        $deploymentName = "user-env-$(($user.UserPrincipalName -replace '@','-' -replace '\.','-').ToLower())-$timestamp"

        # Build parameter set
        $params = @(
            "userPrincipalName=$($user.UserPrincipalName)"
            "userDisplayName=$($user.DisplayName)"
            "userEmail=$($user.Email)"
            "userObjectId=$($user.ObjectId)"
            "location=$Location"
            "department=$($user.Department)"
            "costCenter=$($user.CostCenter)"
            "warningBudgetThreshold=$WarningBudget"
            "hardLimitBudgetThreshold=$HardLimitBudget"
            "gracePeriodDays=$GracePeriodDays"
            "tenantAdminObjectId=$adminObjectId"
            "budgetStartDate=$budgetStartDate"
        )

        if ($WhatIfPreference) {
            # What-if mode
            Write-StepInfo "Running what-if preview..."
            az deployment sub what-if `
                --name $deploymentName `
                --location $Location `
                --template-file $mainBicepFile `
                --parameters $params `
                --no-pretty-print 2>&1 | ForEach-Object { Write-Host "    $_" }

            $results += [PSCustomObject]@{
                User = $user.UserPrincipalName; Status = 'WHAT-IF'; Reason = 'Preview only'
            }
        }
        else {
            # Actual deployment
            Write-StepInfo "Deploying Bicep template (this may take 5-15 minutes)..."
            $deployOutput = az deployment sub create `
                --name $deploymentName `
                --location $Location `
                --template-file $mainBicepFile `
                --parameters $params `
                --output json 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Deployment FAILED for $($user.UserPrincipalName)"
                Write-Host "    $deployOutput" -ForegroundColor Red
                $results += [PSCustomObject]@{
                    User = $user.UserPrincipalName; Status = 'FAILED'; Reason = "$deployOutput"
                }
                continue
            }

            $deployment = $deployOutput | ConvertFrom-Json
            $outputs = $deployment.properties.outputs
            Write-Success "Bicep deployment succeeded"
            Write-StepInfo "  Resource Group: $($outputs.resourceGroupName.value)"
            Write-StepInfo "  AI Hub:         $($outputs.aiFoundryHubName.value)"
            Write-StepInfo "  Budget:         $($outputs.budgetName.value)"
            Write-StepInfo "  Automation:     $($outputs.automationAccountName.value)"

            Confirm-StepContinue "Upload runbook scripts"

            # ── Upload runbook content ──
            Write-StepInfo "Uploading runbook scripts..."
            $rgName = $outputs.resourceGroupName.value
            $aaName = $outputs.automationAccountName.value

            $runbookFiles = @(
                @{ Name = 'Invoke-CostEnforcement';    File = Join-Path $runbooksPath 'Invoke-CostEnforcement.ps1' }
                @{ Name = 'Invoke-GracePeriodCleanup'; File = Join-Path $runbooksPath 'Invoke-GracePeriodCleanup.ps1' }
            )

            foreach ($rb in $runbookFiles) {
                if (-not (Test-Path $rb.File)) {
                    Write-Warn "Runbook file not found: $($rb.File)"
                    continue
                }

                Write-StepInfo "  Importing $($rb.Name)..."

                # Import the runbook content using az CLI
                az automation runbook replace-content `
                    --automation-account-name $aaName `
                    --resource-group $rgName `
                    --name $rb.Name `
                    --content "@$($rb.File)" 2>$null

                if ($LASTEXITCODE -ne 0) {
                    Write-Warn "  CLI import failed, trying REST API fallback..."
                    # Fallback: use REST API to upload runbook content
                    $token = (az account get-access-token --query accessToken -o tsv)
                    $runbookContent = Get-Content -Path $rb.File -Raw
                    $putUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts/$aaName/runbooks/$($rb.Name)/draft/content?api-version=2023-11-01"
                    try {
                        Invoke-RestMethod -Uri $putUri -Method PUT -Body $runbookContent `
                            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'text/powershell' } `
                            -ErrorAction Stop
                        Write-Success "  Uploaded $($rb.Name) via REST API"
                    }
                    catch {
                        Write-Warn "  REST API upload also failed: $_"
                    }
                }
                else {
                    Write-Success "  Uploaded $($rb.Name)"
                }

                # Publish the runbook
                Write-StepInfo "  Publishing $($rb.Name)..."
                az automation runbook publish `
                    --automation-account-name $aaName `
                    --resource-group $rgName `
                    --name $rb.Name 2>$null

                if ($LASTEXITCODE -eq 0) {
                    Write-Success "  Published $($rb.Name)"
                }
                else {
                    Write-Warn "  Failed to publish $($rb.Name)"
                }
            }

            Confirm-StepContinue "Wire webhook for budget enforcement"

            # ── Best-effort: Create webhook and wire to action group ──
            # NOTE: Webhook creation + action group wiring is best-effort.
            # If it fails, the daily scheduled runbook (06:00 UTC) provides backup enforcement.
            Write-StepInfo "Wiring budget enforcement webhook (best-effort)..."
            try {
                $webhookName = "cost-enforce-wh"
                $expiryDate = (Get-Date).AddYears(1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.0000000+00:00')
                $token = (az account get-access-token --query accessToken -o tsv)

                # Create webhook via REST API (no CLI command exists for this)
                $webhookUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts/$aaName/webhooks/${webhookName}?api-version=2015-10-31"
                $webhookBody = @{
                    name = $webhookName
                    properties = @{
                        isEnabled = $true
                        expiryTime = $expiryDate
                        runbook = @{ name = 'Invoke-CostEnforcement' }
                    }
                } | ConvertTo-Json -Depth 4

                $webhookResult = Invoke-RestMethod -Uri $webhookUri -Method PUT -Body $webhookBody `
                    -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
                    -ErrorAction Stop

                if ($webhookResult.properties.uri) {
                    $webhookCallbackUri = $webhookResult.properties.uri
                    Write-Success "  Webhook created"

                    # Update action group with automation runbook receiver via REST API
                    $uniqueSuffix = ($deployment.properties.outputs.budgetName.value -replace 'budget-', '')
                    $agName = "ag-enforce-$uniqueSuffix"
                    $automationAccountId = "/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Automation/automationAccounts/$aaName"
                    $webhookResourceId = "$automationAccountId/webhooks/$webhookName"

                    # Get current action group
                    $agUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Insights/actionGroups/${agName}?api-version=2023-09-01-preview"
                    $agCurrent = Invoke-RestMethod -Uri $agUri -Method GET `
                        -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop

                    # Add automation runbook receiver
                    $agCurrent.properties | Add-Member -NotePropertyName 'automationRunbookReceivers' -NotePropertyValue @(
                        @{
                            name = 'CostEnforce'
                            automationAccountId = $automationAccountId
                            runbookName = 'Invoke-CostEnforcement'
                            webhookResourceId = $webhookResourceId
                            isGlobalRunbook = $false
                            serviceUri = $webhookCallbackUri
                            useCommonAlertSchema = $true
                        }
                    ) -Force

                    $agBody = $agCurrent | ConvertTo-Json -Depth 10
                    Invoke-RestMethod -Uri $agUri -Method PUT -Body $agBody `
                        -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
                        -ErrorAction Stop

                    Write-Success "  Action group wired to runbook webhook"
                }
                else {
                    Write-Warn "  Webhook created but no URI returned (daily schedule is backup)"
                }
            }
            catch {
                Write-Warn "  Webhook wiring failed: $_ (enforcement via daily schedule still active)"
            }

            $results += [PSCustomObject]@{
                User   = $user.UserPrincipalName
                Status = 'SUCCESS'
                Reason = "RG: $rgName"
            }
        }

        Confirm-StepContinue "Process next user"
    }

    # ============================================================================
    # Phase 6: Summary
    # ============================================================================
    Write-Phase "6 - SUMMARY" "Deployment results"

    $results | Format-Table -AutoSize

    # Save results to CSV
    $resultFile = Join-Path $logDir "results-$timestamp.csv"
    $results | Export-Csv -Path $resultFile -NoTypeInformation
    Write-Success "Results saved to $resultFile"

    $succeeded = ($results | Where-Object { $_.Status -eq 'SUCCESS' }).Count
    $failed = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count
    Write-Host ""
    Write-Host "  Succeeded: $succeeded | Failed: $failed | Total: $($results.Count)" -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })

}
catch {
    Write-Host ""
    Write-Host "  FATAL ERROR: $_" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    throw
}
finally {
    Stop-Transcript
    Write-Host ""
    Write-Host "  Log file: $logFile" -ForegroundColor Gray
}

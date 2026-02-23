<#
.SYNOPSIS
    Main orchestration script for provisioning Azure user sandbox environments.

.DESCRIPTION
    This script reads user information from a CSV or JSON input file and provisions
    a complete Azure sandbox environment for each user, including:
      - Azure Subscription (or uses existing one)
      - Resource Group with Azure Policy restrictions
      - RBAC role assignments
      - Azure AI Foundry (Hub + Project)
      - Cost management budgets and enforcement automation

    The script is idempotent and can be run repeatedly. It uses Azure CLI and
    Bicep deployments for infrastructure provisioning.

.PARAMETER InputFile
    Path to the input file (CSV or JSON) containing user information.

.PARAMETER Location
    Azure region for resource deployment. Default: swedencentral

.PARAMETER TenantAdminObjectId
    Object ID of the tenant administrator running this script.
    If not provided, it will be auto-detected from the current Azure CLI session.

.PARAMETER BillingAccountName
    (Optional) EA/MCA Billing Account name for subscription creation.
    If not provided, subscriptions must be pre-created.

.PARAMETER BillingProfileName
    (Optional) Billing Profile name for MCA subscription creation.

.PARAMETER InvoiceSectionName
    (Optional) Invoice Section name for MCA subscription creation.

.PARAMETER EnrollmentAccountName
    (Optional) Enrollment Account name for EA subscription creation.

.PARAMETER SubscriptionOfferType
    Subscription offer type. Default: MS-AZR-0017P (EA Dev/Test)

.PARAMETER WarningBudget
    Budget warning threshold in USD. Default: 15

.PARAMETER HardLimitBudget
    Budget hard limit in USD. Default: 20

.PARAMETER GracePeriodDays
    Days before resources are deleted after hard limit is hit. Default: 5

.PARAMETER WhatIf
    Preview changes without deploying.

.PARAMETER SkipSubscriptionCreation
    Skip subscription creation and use existing subscriptions.
    Requires existing subscription mapping in the input file.

.EXAMPLE
    .\Deploy-UserEnvironment.ps1 -InputFile "..\input\users.csv" -Location "swedencentral"

.EXAMPLE
    .\Deploy-UserEnvironment.ps1 -InputFile "..\input\users.json" -WhatIf

.EXAMPLE
    .\Deploy-UserEnvironment.ps1 -InputFile "..\input\users.csv" -SkipSubscriptionCreation
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ })]
    [string]$InputFile,

    [Parameter(Mandatory = $false)]
    [string]$Location = "swedencentral",

    [Parameter(Mandatory = $false)]
    [string]$TenantAdminObjectId,

    [Parameter(Mandatory = $false)]
    [string]$BillingAccountName,

    [Parameter(Mandatory = $false)]
    [string]$BillingProfileName,

    [Parameter(Mandatory = $false)]
    [string]$InvoiceSectionName,

    [Parameter(Mandatory = $false)]
    [string]$EnrollmentAccountName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionOfferType = "MS-AZR-0017P",

    [Parameter(Mandatory = $false)]
    [int]$WarningBudget = 15,

    [Parameter(Mandatory = $false)]
    [int]$HardLimitBudget = 20,

    [Parameter(Mandatory = $false)]
    [int]$GracePeriodDays = 5,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSubscriptionCreation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================================
# Constants
# ============================================================================
$SCRIPT_DIR = $PSScriptRoot
$INFRA_DIR = Join-Path (Split-Path $SCRIPT_DIR -Parent) "infra"
$RUNBOOKS_DIR = Join-Path $SCRIPT_DIR "runbooks"
$LOG_DIR = Join-Path (Split-Path $SCRIPT_DIR -Parent) "logs"
$MAIN_BICEP = Join-Path $INFRA_DIR "main.bicep"
$BUDGET_START_DATE = (Get-Date -Day 1).ToString("yyyy-MM-01")

# ============================================================================
# Helper Functions
# ============================================================================

function Write-StepHeader {
    param([string]$Message, [int]$Step, [int]$Total)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  Step $Step/$Total: $Message" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-UserHeader {
    param([string]$UserName, [int]$Current, [int]$Total)
    Write-Host ""
    Write-Host ("*" * 70) -ForegroundColor Yellow
    Write-Host "  User $Current/$Total: $UserName" -ForegroundColor Yellow
    Write-Host ("*" * 70) -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [..] $Message" -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!!] $Message" -ForegroundColor DarkYellow
}

function Get-UsersFromFile {
    param([string]$FilePath)

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLower()

    switch ($extension) {
        ".csv" {
            $users = Import-Csv -Path $FilePath
            return $users | ForEach-Object {
                [PSCustomObject]@{
                    UserPrincipalName = $_.UserPrincipalName
                    DisplayName       = $_.DisplayName
                    Email             = $_.Email
                    Department        = $_.Department
                    CostCenter        = $_.CostCenter
                    SubscriptionId    = if ($_.PSObject.Properties['SubscriptionId']) { $_.SubscriptionId } else { "" }
                }
            }
        }
        ".json" {
            $json = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
            $userList = if ($json.users) { $json.users } else { $json }
            return $userList | ForEach-Object {
                [PSCustomObject]@{
                    UserPrincipalName = $_.userPrincipalName
                    DisplayName       = $_.displayName
                    Email             = $_.email
                    Department        = $_.department
                    CostCenter        = $_.costCenter
                    SubscriptionId    = if ($_.subscriptionId) { $_.subscriptionId } else { "" }
                }
            }
        }
        default {
            throw "Unsupported file format: $extension. Use .csv or .json"
        }
    }
}

function Get-UserObjectId {
    param([string]$UserPrincipalName)

    $result = az ad user show --id $UserPrincipalName --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($result)) {
        throw "Could not find Entra ID user: $UserPrincipalName. Ensure the user exists in the tenant."
    }
    return $result.Trim()
}

function New-UserSubscription {
    param(
        [string]$DisplayName,
        [string]$BillingAccount,
        [string]$BillingProfile,
        [string]$InvoiceSection,
        [string]$EnrollmentAccount,
        [string]$OfferType
    )

    $aliasName = "sub-$($DisplayName -replace '\s+', '-' -replace '[^a-zA-Z0-9-]', '' | ForEach-Object { $_.ToLower() })"

    Write-Info "Creating subscription alias: $aliasName"

    if ($BillingProfile -and $InvoiceSection) {
        # MCA billing
        $billingScope = "/providers/Microsoft.Billing/billingAccounts/$BillingAccount/billingProfiles/$BillingProfile/invoiceSections/$InvoiceSection"
        
        $result = az account alias create `
            --name $aliasName `
            --billing-scope $billingScope `
            --display-name "Sandbox - $DisplayName" `
            --workload "DevTest" `
            --query 'properties.subscriptionId' -o tsv 2>&1

    }
    elseif ($EnrollmentAccount) {
        # EA billing
        $billingScope = "/providers/Microsoft.Billing/billingAccounts/$BillingAccount/enrollmentAccounts/$EnrollmentAccount"
        
        $result = az account alias create `
            --name $aliasName `
            --billing-scope $billingScope `
            --display-name "Sandbox - $DisplayName" `
            --workload "DevTest" `
            --query 'properties.subscriptionId' -o tsv 2>&1
    }
    else {
        throw "Either BillingProfile+InvoiceSection (MCA) or EnrollmentAccount (EA) must be provided for subscription creation."
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create subscription: $result"
    }

    return $result.Trim()
}

function Deploy-UserEnvironment {
    param(
        [PSCustomObject]$User,
        [string]$SubscriptionId,
        [string]$AdminObjectId
    )

    $userObjectId = Get-UserObjectId -UserPrincipalName $User.UserPrincipalName
    Write-Info "User Object ID: $userObjectId"

    # Set context to the user's subscription
    Write-Info "Setting subscription context to: $SubscriptionId"
    az account set --subscription $SubscriptionId

    # Validate the Bicep deployment first (what-if)
    Write-Info "Running deployment what-if validation..."
    $whatIfResult = az deployment sub what-if `
        --location $Location `
        --template-file $MAIN_BICEP `
        --parameters `
            userPrincipalName=$($User.UserPrincipalName) `
            userDisplayName="$($User.DisplayName)" `
            userEmail=$($User.Email) `
            userObjectId=$userObjectId `
            location=$Location `
            department="$($User.Department)" `
            costCenter="$($User.CostCenter)" `
            warningBudgetThreshold=$WarningBudget `
            hardLimitBudgetThreshold=$HardLimitBudget `
            gracePeriodDays=$GracePeriodDays `
            tenantAdminObjectId=$AdminObjectId `
            budgetStartDate=$BUDGET_START_DATE `
        2>&1

    if ($WhatIfPreference) {
        Write-Host $whatIfResult
        Write-Warn "WhatIf mode - no changes made."
        return
    }

    # Deploy the Bicep template at subscription scope
    $deploymentName = "user-env-$($User.UserPrincipalName -replace '[@.]', '-')-$(Get-Date -Format 'yyyyMMddHHmm')"
    Write-Info "Deploying environment (deployment: $deploymentName)..."

    $deployResult = az deployment sub create `
        --location $Location `
        --name $deploymentName `
        --template-file $MAIN_BICEP `
        --parameters `
            userPrincipalName=$($User.UserPrincipalName) `
            userDisplayName="$($User.DisplayName)" `
            userEmail=$($User.Email) `
            userObjectId=$userObjectId `
            location=$Location `
            department="$($User.Department)" `
            costCenter="$($User.CostCenter)" `
            warningBudgetThreshold=$WarningBudget `
            hardLimitBudgetThreshold=$HardLimitBudget `
            gracePeriodDays=$GracePeriodDays `
            tenantAdminObjectId=$AdminObjectId `
            budgetStartDate=$BUDGET_START_DATE `
        --query 'properties.outputs' -o json 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Deployment failed: $deployResult"
    }

    $outputs = $deployResult | ConvertFrom-Json
    Write-Success "Deployment successful!"
    Write-Info "Resource Group: $($outputs.resourceGroupName.value)"
    Write-Info "AI Hub: $($outputs.aiFoundryHubName.value)"
    Write-Info "AI Project: $($outputs.aiFoundryProjectName.value)"
    Write-Info "Budget: $($outputs.budgetName.value)"

    # Upload runbook content
    $automationAccountName = $outputs.automationAccountName.value
    $rgName = $outputs.resourceGroupName.value
    Upload-RunbookContent -AutomationAccountName $automationAccountName `
        -ResourceGroupName $rgName

    return $outputs
}

function Upload-RunbookContent {
    param(
        [string]$AutomationAccountName,
        [string]$ResourceGroupName
    )

    Write-Info "Uploading runbook scripts to Automation Account..."

    # Upload cost enforcement runbook
    $enforcementScript = Join-Path $RUNBOOKS_DIR "Invoke-CostEnforcement.ps1"
    if (Test-Path $enforcementScript) {
        az automation runbook replace-content `
            --automation-account-name $AutomationAccountName `
            --resource-group $ResourceGroupName `
            --name "Invoke-CostEnforcement" `
            --content @"$enforcementScript" 2>$null

        az automation runbook publish `
            --automation-account-name $AutomationAccountName `
            --resource-group $ResourceGroupName `
            --name "Invoke-CostEnforcement" 2>$null

        Write-Success "Published Invoke-CostEnforcement runbook."
    }

    # Upload cleanup runbook
    $cleanupScript = Join-Path $RUNBOOKS_DIR "Invoke-GracePeriodCleanup.ps1"
    if (Test-Path $cleanupScript) {
        az automation runbook replace-content `
            --automation-account-name $AutomationAccountName `
            --resource-group $ResourceGroupName `
            --name "Invoke-GracePeriodCleanup" `
            --content @"$cleanupScript" 2>$null

        az automation runbook publish `
            --automation-account-name $AutomationAccountName `
            --resource-group $ResourceGroupName `
            --name "Invoke-GracePeriodCleanup" 2>$null

        Write-Success "Published Invoke-GracePeriodCleanup runbook."
    }
}

# ============================================================================
# Main Execution
# ============================================================================

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host "  AZURE USER SANDBOX ENVIRONMENT PROVISIONING" -ForegroundColor Magenta
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta

# --- Setup logging ---
if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}
$logFile = Join-Path $LOG_DIR "deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logFile -Append

try {
    # ========================================================================
    # Step 1: Validate prerequisites
    # ========================================================================
    Write-StepHeader "Validating prerequisites" 1 6

    # Check Azure CLI is installed
    $azVersion = az version --query '"azure-cli"' -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI is not installed or not in PATH. Install from: https://aka.ms/installazurecli"
    }
    Write-Success "Azure CLI version: $azVersion"

    # Check Bicep is available
    $bicepVersion = az bicep version --query 'bicepVersion' -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Installing Bicep CLI..."
        az bicep install
    }
    Write-Success "Bicep CLI available."

    # Check logged in
    $account = az account show --query '{name:name, id:id, tenantId:tenantId}' -o json 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw "Not logged in to Azure. Run 'az login' first."
    }
    Write-Success "Logged in to tenant: $($account.tenantId)"

    # Get tenant admin Object ID
    if ([string]::IsNullOrWhiteSpace($TenantAdminObjectId)) {
        $TenantAdminObjectId = az ad signed-in-user show --query id -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not determine admin Object ID. Provide -TenantAdminObjectId parameter."
        }
    }
    Write-Success "Tenant Admin Object ID: $TenantAdminObjectId"

    # Validate Bicep template exists
    if (-not (Test-Path $MAIN_BICEP)) {
        throw "Bicep template not found at: $MAIN_BICEP"
    }
    Write-Success "Bicep template found: $MAIN_BICEP"

    # ========================================================================
    # Step 2: Load user input
    # ========================================================================
    Write-StepHeader "Loading user input" 2 6

    $users = Get-UsersFromFile -FilePath $InputFile
    $userCount = @($users).Count
    Write-Success "Loaded $userCount user(s) from: $InputFile"

    foreach ($user in $users) {
        Write-Info "  - $($user.DisplayName) ($($user.UserPrincipalName))"
    }

    # ========================================================================
    # Step 3: Validate users exist in Entra ID
    # ========================================================================
    Write-StepHeader "Validating users in Entra ID" 3 6

    $validUsers = @()
    foreach ($user in $users) {
        try {
            $objectId = Get-UserObjectId -UserPrincipalName $user.UserPrincipalName
            Write-Success "$($user.DisplayName) found (ObjectId: $objectId)"
            $validUsers += $user
        }
        catch {
            Write-Warn "User not found: $($user.UserPrincipalName) - SKIPPING"
        }
    }

    if ($validUsers.Count -eq 0) {
        throw "No valid users found. Aborting."
    }

    # ========================================================================
    # Step 4: Create/Validate subscriptions
    # ========================================================================
    Write-StepHeader "Managing subscriptions" 4 6

    $userSubscriptions = @{}

    foreach ($user in $validUsers) {
        if ($SkipSubscriptionCreation -or [string]::IsNullOrWhiteSpace($BillingAccountName)) {
            if (-not [string]::IsNullOrWhiteSpace($user.SubscriptionId)) {
                $userSubscriptions[$user.UserPrincipalName] = $user.SubscriptionId
                Write-Success "$($user.DisplayName) -> existing subscription: $($user.SubscriptionId)"
            }
            else {
                # Use the current subscription as fallback
                $currentSub = az account show --query id -o tsv
                $userSubscriptions[$user.UserPrincipalName] = $currentSub
                Write-Warn "$($user.DisplayName) -> using current subscription: $currentSub"
                Write-Warn "  For production use, provide subscription IDs in the input file"
                Write-Warn "  or configure billing parameters for automatic subscription creation."
            }
        }
        else {
            Write-Info "Creating subscription for $($user.DisplayName)..."
            try {
                $subId = New-UserSubscription `
                    -DisplayName $user.DisplayName `
                    -BillingAccount $BillingAccountName `
                    -BillingProfile $BillingProfileName `
                    -InvoiceSection $InvoiceSectionName `
                    -EnrollmentAccount $EnrollmentAccountName `
                    -OfferType $SubscriptionOfferType

                $userSubscriptions[$user.UserPrincipalName] = $subId
                Write-Success "$($user.DisplayName) -> new subscription: $subId"
            }
            catch {
                Write-Warn "Failed to create subscription for $($user.DisplayName): $_"
                Write-Warn "Falling back to current subscription."
                $currentSub = az account show --query id -o tsv
                $userSubscriptions[$user.UserPrincipalName] = $currentSub
            }
        }
    }

    # ========================================================================
    # Step 5: Deploy environments
    # ========================================================================
    Write-StepHeader "Deploying user environments" 5 6

    $results = @()
    $userIndex = 0

    foreach ($user in $validUsers) {
        $userIndex++
        Write-UserHeader -UserName $user.DisplayName -Current $userIndex -Total $validUsers.Count

        $subscriptionId = $userSubscriptions[$user.UserPrincipalName]
        
        try {
            $outputs = Deploy-UserEnvironment `
                -User $user `
                -SubscriptionId $subscriptionId `
                -AdminObjectId $TenantAdminObjectId

            $results += [PSCustomObject]@{
                User           = $user.DisplayName
                UPN            = $user.UserPrincipalName
                SubscriptionId = $subscriptionId
                Status         = "Success"
                ResourceGroup  = if ($outputs) { $outputs.resourceGroupName.value } else { "N/A (WhatIf)" }
                AIHub          = if ($outputs) { $outputs.aiFoundryHubName.value } else { "N/A" }
                Error          = ""
            }
            Write-Success "Environment deployed for $($user.DisplayName)"
        }
        catch {
            Write-Warn "FAILED: $($user.DisplayName) - $_"
            $results += [PSCustomObject]@{
                User           = $user.DisplayName
                UPN            = $user.UserPrincipalName
                SubscriptionId = $subscriptionId
                Status         = "Failed"
                ResourceGroup  = "N/A"
                AIHub          = "N/A"
                Error          = $_.ToString()
            }
        }
    }

    # ========================================================================
    # Step 6: Summary
    # ========================================================================
    Write-StepHeader "Deployment Summary" 6 6

    $successCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
    $failedCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count

    Write-Host ""
    Write-Host "  Total Users:  $($results.Count)" -ForegroundColor White
    Write-Host "  Successful:   $successCount" -ForegroundColor Green
    Write-Host "  Failed:       $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "Green" })
    Write-Host ""

    # Display results table
    $results | Format-Table -AutoSize -Property User, UPN, SubscriptionId, Status, ResourceGroup, AIHub

    # Export results
    $resultsFile = Join-Path $LOG_DIR "results-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    $results | Export-Csv -Path $resultsFile -NoTypeInformation
    Write-Success "Results exported to: $resultsFile"

    if ($failedCount -gt 0) {
        Write-Warn "Some deployments failed. Review the log file for details: $logFile"
    }
}
catch {
    Write-Host ""
    Write-Host "FATAL ERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
finally {
    Stop-Transcript
    Write-Host ""
    Write-Host "Log file: $logFile" -ForegroundColor Gray
}

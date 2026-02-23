<#
.SYNOPSIS
    STEP 1: Create Azure subscriptions for users under a shared billing account.

.DESCRIPTION
    Creates one Azure subscription per user from the input CSV/JSON file.
    All subscriptions are created under the SAME billing account to ensure
    centralized cost management and billing visibility.

    FOR TESTING: Skip this script entirely. Instead, add your existing
    subscription ID to the SubscriptionId column in your CSV/JSON file.
    The deployment script (Step 2) will use that subscription.

    SUPPORTED BILLING TYPES:
      - Microsoft Customer Agreement (MCA):    FULLY SUPPORTED
        Billing scope: /providers/Microsoft.Billing/billingAccounts/{id}/billingProfiles/{id}/invoiceSections/{id}
      - Enterprise Agreement (EA):              FULLY SUPPORTED
        Billing scope: /providers/Microsoft.Billing/billingAccounts/{id}/enrollmentAccounts/{id}
      - Modern Pay-As-You-Go (post-2019):       FULLY SUPPORTED (uses MCA format)

    UNSUPPORTED (subscriptions must be created manually):
      - CSP (Cloud Solution Provider):          Partner must create subscriptions via Partner Center
      - Legacy MOSP (pre-2019 Pay-As-You-Go):  No programmatic subscription creation API

    If your billing type is unsupported, skip this script and add existing
    SubscriptionId values to your CSV/JSON file manually. Step 2 will use them.

    PREREQUISITES:
      - You must be logged in to Azure CLI (az login)
      - You must have Owner or Contributor permissions on the billing account
      - The billing account must be in the same tenant

    HOW TO FIND YOUR BILLING SCOPE:
      1. Run: az billing account list -o table
      2. Note your billing account name and agreement type
      3. For MCA, also run:
         az billing profile list --account-name "NAME" -o table
         az billing invoice section list --account-name "NAME" --profile-name "NAME" -o table
      4. Build the billing scope string from those IDs

    HOW TO CHECK YOUR BILLING TYPE:
      Run: az billing account list --query "[].{Name:displayName, Type:agreementType}" -o table
      If the Type column shows 'MicrosoftCustomerAgreement' or 'EnterpriseAgreement', you can
      use this script. If it shows 'MicrosoftPartnerAgreement' (CSP) or 'MicrosoftOnlineServiceProgram'
      (legacy MOSP), you must create subscriptions manually.

.PARAMETER InputFile
    Path to CSV or JSON file with user definitions.

.PARAMETER BillingScope
    The full billing scope path (see description for format).

.PARAMETER OutputFile
    Path to save the updated input file with SubscriptionId filled in.
    Default: output/users-with-subscriptions-{timestamp}.{csv|json}

.PARAMETER WhatIf
    Preview which subscriptions would be created without creating them.

.EXAMPLE
    # Step 1: Create subscriptions
    ./New-UserSubscriptions.ps1 `
        -InputFile "../input/users.csv" `
        -BillingScope "/providers/Microsoft.Billing/billingAccounts/XXXX/billingProfiles/XXXX/invoiceSections/XXXX"

    # For testing: skip this script and add SubscriptionId to your CSV instead

.EXAMPLE
    # Preview only (dry run)
    ./New-UserSubscriptions.ps1 `
        -InputFile "../input/users.csv" `
        -BillingScope "/providers/Microsoft.Billing/billingAccounts/XXXX/enrollmentAccounts/XXXX" `
        -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ })]
    [string]$InputFile,

    [Parameter(Mandatory = $true)]
    [string]$BillingScope,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = ''
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Helper Functions
# ============================================================================
function Read-UserInput {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    if ($ext -eq '.csv') {
        return @(Import-Csv -Path $FilePath)
    }
    elseif ($ext -eq '.json') {
        $json = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
        return @(if ($json.users) { $json.users } else { $json })
    }
    else { throw "Unsupported file type: $ext. Use .csv or .json." }
}

function Write-StepInfo { param([string]$M) Write-Host "  -> $M" -ForegroundColor White }
function Write-Success  { param([string]$M) Write-Host "  OK $M" -ForegroundColor Green }
function Write-Warn     { param([string]$M) Write-Host "  !! $M" -ForegroundColor Yellow }

# ============================================================================
# Main
# ============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  STEP 1: Azure Subscription Creation" -ForegroundColor Cyan
Write-Host "  All subscriptions will be under the same billing account" -ForegroundColor Gray
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Check authentication
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    throw @"
Not logged in to Azure.

Run this command first:
  az login --tenant YOUR_TENANT_ID

Replace YOUR_TENANT_ID with your Azure tenant ID (you can find this in the
Azure Portal under 'Microsoft Entra ID' > 'Overview' > 'Tenant ID').
"@
}

Write-Host "  Logged in as:    $($account.user.name)" -ForegroundColor Green
Write-Host "  Tenant:          $($account.tenantId)" -ForegroundColor Gray
Write-Host "  Billing scope:   $BillingScope" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# Detect billing type and warn if unsupported
# ============================================================================
Write-StepInfo "Checking billing account type..."
try {
    $billingAccounts = az billing account list --query "[].{name:name, displayName:displayName, agreementType:agreementType}" -o json 2>$null | ConvertFrom-Json
    if ($billingAccounts) {
        $billingAccounts | ForEach-Object {
            Write-Host "    Billing account: $($_.displayName)  Type: $($_.agreementType)" -ForegroundColor Gray
        }
        $agreementTypes = $billingAccounts | Select-Object -ExpandProperty agreementType -Unique
        $hasCSP = $agreementTypes -contains 'MicrosoftPartnerAgreement'
        $hasMOSP = $agreementTypes -contains 'MicrosoftOnlineServiceProgram'

        if ($hasCSP) {
            Write-Host "" -ForegroundColor Yellow
            Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
            Write-Host "  ║  CSP (Cloud Solution Provider) BILLING DETECTED                ║" -ForegroundColor Yellow
            Write-Host "  ╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Yellow
            Write-Host "  ║  CSP subscriptions must be created by your CSP partner          ║" -ForegroundColor Yellow
            Write-Host "  ║  through the Partner Center portal. This script cannot create   ║" -ForegroundColor Yellow
            Write-Host "  ║  subscriptions under a CSP billing arrangement.                 ║" -ForegroundColor Yellow
            Write-Host "  ║                                                                 ║" -ForegroundColor Yellow
            Write-Host "  ║  WHAT TO DO:                                                    ║" -ForegroundColor Yellow
            Write-Host "  ║  1. Ask your CSP partner to create subscriptions for each user  ║" -ForegroundColor Yellow
            Write-Host "  ║  2. Get the Subscription ID for each new subscription           ║" -ForegroundColor Yellow
            Write-Host "  ║  3. Add them to the SubscriptionId column in your CSV/JSON      ║" -ForegroundColor Yellow
            Write-Host "  ║  4. Skip this script and go directly to Step 2                  ║" -ForegroundColor Yellow
            Write-Host "  ║                                                                 ║" -ForegroundColor Yellow
            Write-Host "  ║  All subscriptions will still be under the same CSP billing     ║" -ForegroundColor Yellow
            Write-Host "  ║  account — your partner manages the centralized billing.        ║" -ForegroundColor Yellow
            Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
            Write-Host ""
            $continue = Read-Host "  Continue anyway? (y to proceed, any other key to exit)"
            if ($continue -ne 'y') {
                Write-Host "  Exiting. Create subscriptions via your CSP partner, then run Step 2." -ForegroundColor Cyan
                exit 0
            }
        }

        if ($hasMOSP) {
            Write-Host "" -ForegroundColor Yellow
            Write-Host "  ╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
            Write-Host "  ║  LEGACY PAY-AS-YOU-GO (MOSP) BILLING DETECTED                  ║" -ForegroundColor Yellow
            Write-Host "  ╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Yellow
            Write-Host "  ║  Legacy MOSP accounts do not support programmatic subscription  ║" -ForegroundColor Yellow
            Write-Host "  ║  creation. You have two options:                                ║" -ForegroundColor Yellow
            Write-Host "  ║                                                                 ║" -ForegroundColor Yellow
            Write-Host "  ║  Option 1: Upgrade to Microsoft Customer Agreement (MCA)        ║" -ForegroundColor Yellow
            Write-Host "  ║    In Azure Portal: Cost Management > Billing > Upgrade         ║" -ForegroundColor Yellow
            Write-Host "  ║    Then re-run this script.                                     ║" -ForegroundColor Yellow
            Write-Host "  ║                                                                 ║" -ForegroundColor Yellow
            Write-Host "  ║  Option 2: Create subscriptions manually                       ║" -ForegroundColor Yellow
            Write-Host "  ║    In Azure Portal: Subscriptions > Add                         ║" -ForegroundColor Yellow
            Write-Host "  ║    Add each Subscription ID to your CSV/JSON                    ║" -ForegroundColor Yellow
            Write-Host "  ║    Then skip this script and go to Step 2                       ║" -ForegroundColor Yellow
            Write-Host "  ╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
            Write-Host ""
            $continue = Read-Host "  Continue anyway? (y to proceed, any other key to exit)"
            if ($continue -ne 'y') {
                Write-Host "  Exiting. Create subscriptions manually or upgrade to MCA, then run Step 2." -ForegroundColor Cyan
                exit 0
            }
        }

        if (-not $hasCSP -and -not $hasMOSP) {
            Write-Success "Billing type supported for programmatic subscription creation"
        }
    }
    else {
        Write-Warn "Could not list billing accounts (you may lack billing reader permissions)"
    }
}
catch {
    Write-Warn "Could not detect billing type: $_"
    Write-Host "    Continuing with provided billing scope..." -ForegroundColor Gray
}

# Read users
$users = Read-UserInput -FilePath $InputFile
Write-StepInfo "Found $($users.Count) user(s) in input file"

# Validate billing scope
Write-StepInfo "Validating billing scope..."
try {
    $token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
    $billingUri = "https://management.azure.com$($BillingScope)?api-version=2024-04-01"
    $null = Invoke-RestMethod -Uri $billingUri -Method GET `
        -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
    Write-Success "Billing scope validated"
}
catch {
    Write-Warn "Could not validate billing scope: $_"
    Write-Host ""
    Write-Host "  To find your billing scope, run these commands:" -ForegroundColor Yellow
    Write-Host "    az billing account list -o table" -ForegroundColor Gray
    Write-Host "    az billing profile list --account-name NAME -o table" -ForegroundColor Gray
    Write-Host "    az billing invoice section list --account-name NAME --profile-name NAME -o table" -ForegroundColor Gray
    Write-Host ""
    $continue = Read-Host "  Continue anyway? (y/n)"
    if ($continue -ne 'y') { exit 0 }
}

# Prepare output
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputFile) {
    $outputDir = Join-Path (Split-Path $PSScriptRoot) 'output'
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $ext = [System.IO.Path]::GetExtension($InputFile).ToLower()
    $OutputFile = Join-Path $outputDir "users-with-subscriptions-$timestamp$ext"
}

Write-Host ""
$results = @()

foreach ($user in $users) {
    $upn = if ($user.UserPrincipalName) { $user.UserPrincipalName } else { $user.userPrincipalName }
    $displayName = if ($user.DisplayName) { $user.DisplayName } else { $user.displayName }
    $existingSub = if ($user.SubscriptionId) { $user.SubscriptionId } elseif ($user.subscriptionId) { $user.subscriptionId } else { '' }

    Write-Host "  Processing: $displayName ($upn)" -ForegroundColor White

    # Skip if already has a subscription
    if ($existingSub) {
        Write-Host "    Already has subscription: $existingSub. Skipping." -ForegroundColor Yellow
        $results += [PSCustomObject]@{
            UserPrincipalName = $upn
            DisplayName       = $displayName
            SubscriptionId    = $existingSub
            Status            = 'EXISTING'
        }
        continue
    }

    $aliasName = "sub-$($upn -replace '@','-' -replace '\.','-')".ToLower()
    $subDisplayName = "Sandbox - $displayName"

    if ($WhatIfPreference) {
        Write-Host "    [WhatIf] Would create subscription '$subDisplayName'" -ForegroundColor Cyan
        $results += [PSCustomObject]@{
            UserPrincipalName = $upn
            DisplayName       = $displayName
            SubscriptionId    = '(would be created)'
            Status            = 'WHATIF'
        }
        continue
    }

    Write-StepInfo "Creating subscription '$subDisplayName'..."
    try {
        $token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
        $aliasUri = "https://management.azure.com/providers/Microsoft.Subscription/aliases/${aliasName}?api-version=2021-10-01"
        $body = @{
            properties = @{
                displayName  = $subDisplayName
                billingScope = $BillingScope
                workload     = 'Production'
            }
        } | ConvertTo-Json -Depth 3

        $response = Invoke-RestMethod -Uri $aliasUri -Method PUT -Body $body `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } `
            -ErrorAction Stop

        # Subscription creation is async — poll for completion
        $subscriptionId = $response.properties.subscriptionId
        if (-not $subscriptionId -and $response.properties.provisioningState -eq 'Accepted') {
            Write-StepInfo "  Subscription creation in progress, waiting..."
            $maxWait = 120  # seconds
            $waited = 0
            while ($waited -lt $maxWait) {
                Start-Sleep -Seconds 10
                $waited += 10
                $pollResponse = Invoke-RestMethod -Uri $aliasUri -Method GET `
                    -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
                if ($pollResponse.properties.subscriptionId) {
                    $subscriptionId = $pollResponse.properties.subscriptionId
                    break
                }
                if ($pollResponse.properties.provisioningState -eq 'Failed') {
                    throw "Subscription provisioning failed"
                }
            }
        }

        if ($subscriptionId) {
            Write-Success "Created! Subscription ID: $subscriptionId"
            $results += [PSCustomObject]@{
                UserPrincipalName = $upn
                DisplayName       = $displayName
                SubscriptionId    = $subscriptionId
                Status            = 'CREATED'
            }
        }
        else {
            throw "Subscription creation timed out after ${maxWait}s"
        }
    }
    catch {
        Write-Host "    FAILED: $_" -ForegroundColor Red
        $results += [PSCustomObject]@{
            UserPrincipalName = $upn
            DisplayName       = $displayName
            SubscriptionId    = ''
            Status            = 'FAILED'
        }
    }
}

# ============================================================================
# Output — Save updated input file with subscription IDs
# ============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  RESULTS" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$results | Format-Table UserPrincipalName, Status, SubscriptionId -AutoSize

# Save updated input file
$ext = [System.IO.Path]::GetExtension($InputFile).ToLower()
if ($ext -eq '.csv') {
    $originalUsers = Import-Csv -Path $InputFile
    foreach ($orig in $originalUsers) {
        $match = $results | Where-Object { $_.UserPrincipalName -eq $orig.UserPrincipalName }
        if ($match -and $match.SubscriptionId -and $match.Status -ne 'FAILED' -and $match.Status -ne 'WHATIF') {
            if (-not ($orig | Get-Member -Name 'SubscriptionId' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                $orig | Add-Member -NotePropertyName 'SubscriptionId' -NotePropertyValue $match.SubscriptionId
            }
            else {
                $orig.SubscriptionId = $match.SubscriptionId
            }
        }
    }
    $originalUsers | Export-Csv -Path $OutputFile -NoTypeInformation
}
elseif ($ext -eq '.json') {
    $json = Get-Content -Path $InputFile -Raw | ConvertFrom-Json
    $userArray = if ($json.users) { $json.users } else { $json }
    foreach ($u in $userArray) {
        $matchUpn = if ($u.userPrincipalName) { $u.userPrincipalName } else { $u.UserPrincipalName }
        $match = $results | Where-Object { $_.UserPrincipalName -eq $matchUpn }
        if ($match -and $match.SubscriptionId -and $match.Status -ne 'FAILED' -and $match.Status -ne 'WHATIF') {
            if (-not ($u | Get-Member -Name 'subscriptionId' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                $u | Add-Member -NotePropertyName 'subscriptionId' -NotePropertyValue $match.SubscriptionId
            }
            else {
                $u.subscriptionId = $match.SubscriptionId
            }
        }
    }
    $json | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile
}

Write-Host "  Updated input file saved to: $OutputFile" -ForegroundColor Green
Write-Host ""
Write-Host "  NEXT STEP: Use the updated file for deployment (Step 2):" -ForegroundColor Yellow
Write-Host "    pwsh ./Deploy-UserEnvironment.ps1 -InputFile `"$OutputFile`"" -ForegroundColor Gray
Write-Host ""

$created = ($results | Where-Object { $_.Status -eq 'CREATED' }).Count
$failed = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count
Write-Host "  Created: $created | Existing: $(($results | Where-Object { $_.Status -eq 'EXISTING' }).Count) | Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ""

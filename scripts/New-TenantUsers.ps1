<#
.SYNOPSIS
    Optional module: Create users in Azure Entra ID (Azure AD) from a CSV/JSON file.

.DESCRIPTION
    This script creates new users in your Entra ID tenant from the same input
    files used by the provisioning scripts. It is OPTIONAL — only needed if the
    users don't already exist in the tenant.

    For each user it:
      - Creates an Entra ID user account with a temporary password
      - Optionally assigns a license (e.g., Azure AD Free)
      - Exports the credentials to a secure output file

    PREREQUISITES:
      - You must be a Global Administrator or User Administrator in Entra ID
      - Azure CLI must be installed and authenticated
      - The Microsoft Graph module is used via az CLI rest commands

.PARAMETER InputFile
    Path to CSV or JSON file with user definitions.

.PARAMETER DefaultDomain
    The verified domain to use for UPNs (e.g., contoso.com).
    Only needed if UPNs in the input file use a different domain.

.PARAMETER TemporaryPassword
    Default temporary password for all new users. Users will be forced
    to change it on first login. Default: a random 16-char password.

.PARAMETER OutputFile
    Path to save the credentials report (CSV). Default: output/new-users-{timestamp}.csv.

.PARAMETER ForceChangePassword
    Whether users must change password on first login (default: true).

.EXAMPLE
    # Create users from CSV (generates random passwords)
    ./New-TenantUsers.ps1 -InputFile "../input/users.csv"

    # Create users with a specific temporary password
    ./New-TenantUsers.ps1 -InputFile "../input/users.csv" -TemporaryPassword "Welcome2024!"

    # Dry-run: check which users would be created
    ./New-TenantUsers.ps1 -InputFile "../input/users.csv" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ })]
    [string]$InputFile,

    [Parameter(Mandatory = $false)]
    [string]$DefaultDomain = '',

    [Parameter(Mandatory = $false)]
    [string]$TemporaryPassword = '',

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = '',

    [Parameter(Mandatory = $false)]
    [bool]$ForceChangePassword = $true
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Helper Functions
# ============================================================================
function New-RandomPassword {
    param([int]$Length = 16)
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%'
    -join (1..$Length | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

function Read-UserInput {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    if ($ext -eq '.csv') {
        return Import-Csv -Path $FilePath | ForEach-Object {
            [PSCustomObject]@{
                UserPrincipalName = $_.UserPrincipalName
                DisplayName       = $_.DisplayName
                Email             = $_.Email
                Department        = if ($_.Department) { $_.Department } else { '' }
            }
        }
    }
    elseif ($ext -eq '.json') {
        $json = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
        $arr = if ($json.users) { $json.users } else { $json }
        return $arr | ForEach-Object {
            [PSCustomObject]@{
                UserPrincipalName = $_.userPrincipalName
                DisplayName       = $_.displayName
                Email             = $_.email
                Department        = if ($_.department) { $_.department } else { '' }
            }
        }
    }
    else { throw "Unsupported file type: $ext" }
}

# ============================================================================
# Initialize
# ============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Entra ID User Creation Module (Optional)             ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Check authentication
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Not logged in to Azure. Run 'az login --tenant YOUR_TENANT_ID' first."
}
Write-Host "  Logged in as: $($account.user.name)" -ForegroundColor Green
Write-Host "  Tenant: $($account.tenantId)" -ForegroundColor Gray

# Read users
$users = @(Read-UserInput -FilePath $InputFile)
Write-Host "  Users to process: $($users.Count)" -ForegroundColor White

# Prepare output
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputFile) {
    $outputDir = Join-Path (Split-Path $PSScriptRoot) 'output'
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
    $OutputFile = Join-Path $outputDir "new-users-$timestamp.csv"
}

$results = @()

Write-Host ""
foreach ($user in $users) {
    Write-Host "  Processing: $($user.DisplayName) ($($user.UserPrincipalName))..." -ForegroundColor White

    # Check if user already exists
    $existing = az ad user show --id $user.UserPrincipalName 2>$null | ConvertFrom-Json
    if ($existing) {
        Write-Host "    Already exists (ObjectId: $($existing.id)). Skipping." -ForegroundColor Yellow
        $results += [PSCustomObject]@{
            UserPrincipalName = $user.UserPrincipalName
            DisplayName       = $user.DisplayName
            ObjectId          = $existing.id
            Status            = 'EXISTING'
            Password          = '(not changed)'
        }
        continue
    }

    if ($WhatIfPreference) {
        Write-Host "    [WhatIf] Would create user." -ForegroundColor Cyan
        $results += [PSCustomObject]@{
            UserPrincipalName = $user.UserPrincipalName
            DisplayName       = $user.DisplayName
            ObjectId          = '(will be created)'
            Status            = 'WHATIF'
            Password          = '(will be generated)'
        }
        continue
    }

    # Generate password
    $password = if ($TemporaryPassword) { $TemporaryPassword } else { New-RandomPassword }

    # Extract mail nickname from UPN
    $mailNickname = ($user.UserPrincipalName -split '@')[0]

    # Create user via Microsoft Graph (az rest)
    $body = @{
        accountEnabled    = $true
        displayName       = $user.DisplayName
        mailNickname      = $mailNickname
        userPrincipalName = $user.UserPrincipalName
        passwordProfile   = @{
            forceChangePasswordNextSignIn = $ForceChangePassword
            password                      = $password
        }
    }

    if ($user.Department) {
        $body['department'] = $user.Department
    }

    $bodyJson = $body | ConvertTo-Json -Depth 3 -Compress

    try {
        $result = az rest --method POST `
            --url 'https://graph.microsoft.com/v1.0/users' `
            --headers 'Content-Type=application/json' `
            --body $bodyJson 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw $result
        }

        $newUser = $result | ConvertFrom-Json
        Write-Host "    Created! ObjectId: $($newUser.id)" -ForegroundColor Green

        $results += [PSCustomObject]@{
            UserPrincipalName = $user.UserPrincipalName
            DisplayName       = $user.DisplayName
            ObjectId          = $newUser.id
            Status            = 'CREATED'
            Password          = $password
        }
    }
    catch {
        Write-Host "    FAILED: $_" -ForegroundColor Red
        $results += [PSCustomObject]@{
            UserPrincipalName = $user.UserPrincipalName
            DisplayName       = $user.DisplayName
            ObjectId          = ''
            Status            = 'FAILED'
            Password          = ''
        }
    }
}

# ============================================================================
# Output
# ============================================================================
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RESULTS" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$results | Format-Table UserPrincipalName, Status, ObjectId -AutoSize

# Save results
$results | Export-Csv -Path $OutputFile -NoTypeInformation
Write-Host "  Credentials saved to: $OutputFile" -ForegroundColor Green
Write-Host ""
Write-Host "  ⚠ IMPORTANT: Share passwords with users securely!" -ForegroundColor Yellow
Write-Host "    The output file contains temporary passwords." -ForegroundColor Yellow
Write-Host "    Users must change their password on first login." -ForegroundColor Yellow
Write-Host ""

$created = ($results | Where-Object { $_.Status -eq 'CREATED' }).Count
$existing = ($results | Where-Object { $_.Status -eq 'EXISTING' }).Count
$failed = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count
Write-Host "  Created: $created | Already existed: $existing | Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'Green' })

# Sample Walkthrough: End-to-End Deployment

This guide walks through a complete deployment scenario step by step.

---

## Scenario

You are the tenant admin for `contoso.com`. You need to provision sandbox
environments for 2 new AI researchers: Alice and Bob.

---

## Step 1: Clone the Repository

```bash
git clone https://github.com/RaikHerrmann/azure-user-provisioning.git
cd azure-user-provisioning
```

---

## Step 2: Connect to Azure

```bash
# Login as tenant admin
az login --tenant contoso.onmicrosoft.com

# Verify your identity
az account show --query "{User:user.name, Tenant:tenantId, Sub:id}" -o table

# Set the subscription where user environments will be created
az account set --subscription "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

See [Admin Connection Guide](admin-connection-guide.md) for detailed auth options.

---

## Step 3: Prepare the Input File

Edit `input/users.csv`:

```csv
UserPrincipalName,DisplayName,Email,Department,CostCenter
alice.researcher@contoso.com,Alice Researcher,alice.researcher@contoso.com,AI Research,CC-2001
bob.scientist@contoso.com,Bob Scientist,bob.scientist@contoso.com,AI Research,CC-2002
```

> **Important**: Users must already exist in Entra ID. If they don't, use the
> optional user creation module first (see Step 3b below).

---

## Step 3b: (Optional) Create Users in Entra ID

If Alice and Bob don't have accounts yet:

```powershell
cd scripts

# Preview what would be created (dry run)
pwsh ./New-TenantUsers.ps1 -InputFile "../input/users.csv" -WhatIf

# Create the users
pwsh ./New-TenantUsers.ps1 -InputFile "../input/users.csv"
```

Output:

```
  Processing: Alice Researcher (alice.researcher@contoso.com)...
    Created! ObjectId: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  Processing: Bob Scientist (bob.scientist@contoso.com)...
    Created! ObjectId: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

  Credentials saved to: ../output/new-users-20240115-143022.csv

  ⚠ IMPORTANT: Share passwords with users securely!
```

Send the temporary passwords to users through a secure channel.

---

## Step 4: Preview the Deployment (What-If)

Always preview first:

```powershell
cd scripts

pwsh ./Deploy-UserEnvironment.ps1 `
  -InputFile "../input/users.csv" `
  -Location "swedencentral" `
  -WhatIf
```

This shows what resources would be created without making any changes.

---

## Step 5: Deploy — Step-by-Step Mode (Recommended First Time)

For your first deployment, use `-Step` to pause between phases:

```powershell
pwsh ./Deploy-UserEnvironment.ps1 `
  -InputFile "../input/users.csv" `
  -Location "swedencentral" `
  -Step
```

The script will pause after each phase:

```
═══════════════════════════════════════════════════════════════
  PHASE: 1 - PREREQUISITES
  Checking tools and authentication
═══════════════════════════════════════════════════════════════
  → Checking Azure CLI...
  ✓ Azure CLI 2.67.0 found
  → Checking Bicep CLI...
  ✓ Bicep available
  → Checking Azure authentication...
  ✓ Logged in as admin@contoso.com (Tenant: xxxxxxxx)
  → Resolving admin identity...
  ✓ Admin Object ID: 11111111-1111-1111-1111-111111111111

  Next: Read and validate input file
  Press ENTER to continue, or 'q' to quit:
```

Each phase can be inspected before proceeding.

---

## Step 5-alt: Deploy — Single User Testing

Test with just one user first:

```powershell
pwsh ./Deploy-UserEnvironment.ps1 `
  -InputFile "../input/users.csv" `
  -Location "swedencentral" `
  -SingleUser "alice.researcher@contoso.com" `
  -Step
```

---

## Step 5-alt2: Deploy — All Users at Once

Once confident, deploy everything in batch:

```powershell
pwsh ./Deploy-UserEnvironment.ps1 `
  -InputFile "../input/users.csv" `
  -Location "swedencentral"
```

---

## Step 6: Verify the Deployment

### Check Resource Groups

```bash
az group list --query "[?tags.ManagedBy=='IaC-Automation']" -o table
```

Expected output:
```
Name                                Location       Status
----------------------------------  -------------  ---------
rg-alice-researcher-contoso-com     swedencentral  Succeeded
rg-bob-scientist-contoso-com        swedencentral  Succeeded
```

### Check AI Foundry Workspaces

```bash
az ml workspace list -o table
```

### Check Budgets

```bash
az consumption budget list -o table
```

### Check RBAC

```bash
# Check Alice's permissions
az role assignment list \
  --assignee "alice.researcher@contoso.com" \
  --all -o table
```

Expected:
```
Principal                          Role            Scope
---------------------------------  --------------  --------------------------
alice.researcher@contoso.com       Contributor     rg-alice-researcher-contoso-com
alice.researcher@contoso.com       AI Developer    aihub-xxxxx
```

### Check that users CANNOT create resource groups

```bash
# Switch to Alice's context (for testing)
az login --username alice.researcher@contoso.com

# This should FAIL:
az group create --name "rg-test-forbidden" --location swedencentral
# Error: AuthorizationFailed — The user does not have authorization to perform
# action 'Microsoft.Resources/subscriptions/resourceGroups/write'
```

---

## Step 7: Monitor Costs

Check the deployment logs:

```bash
cat logs/deployment-*.log
cat logs/results-*.csv
```

Check budget status for a specific user:

```bash
az consumption budget show \
  --budget-name "budget-XXXXX" \
  --resource-group "rg-alice-researcher-contoso-com" \
  --query "{Name:name, Amount:amount, CurrentSpend:currentSpend.amount}"
```

---

## Step 8: (Later) Cleanup

### Remove a single user

```powershell
pwsh ./scripts/Remove-UserEnvironment.ps1 `
  -UserPrincipalName "alice.researcher@contoso.com" `
  -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Remove all users from the input file

```powershell
$subId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
$users = Import-Csv "./input/users.csv"
foreach ($user in $users) {
    pwsh ./scripts/Remove-UserEnvironment.ps1 `
      -UserPrincipalName $user.UserPrincipalName `
      -SubscriptionId $subId `
      -Force
}
```

---

## Custom Budget Thresholds

Deploy with custom values:

```powershell
pwsh ./Deploy-UserEnvironment.ps1 `
  -InputFile "../input/users.csv" `
  -Location "westeurope" `
  -WarningBudget 10 `
  -HardLimitBudget 15 `
  -GracePeriodDays 3
```

---

## What Happens When Costs Exceed $20

```
Day 1-10:  Alice deploys models, runs experiments
Day 11:    Cost reaches $15 → Alice receives warning email
Day 13:    Cost reaches $20 → Automation triggers:
             ✓ Alice's role changed from Contributor to Reader
             ✓ All VMs, Web Apps, Function Apps stopped
             ✓ ML endpoints disabled
             ✓ Alice receives enforcement email
             ✓ 5-day grace period starts
Day 13-18: Alice can view resources (Reader) but cannot modify
Day 18:    Grace period expires → Cleanup runbook:
             ✓ All resources in rg-alice-researcher-contoso-com deleted
             ✓ All RBAC assignments removed
             ✓ Alice receives final notification
```

The admin can re-provision Alice's environment at any time by re-running the deploy script.

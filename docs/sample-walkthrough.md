# Sample Walkthrough: End-to-End Deployment

This guide walks you through the **complete deployment process** step by step. It is written for administrators who have **beginner-level Azure experience**.

The deployment is split into **two main steps**:
1. **Step 1**: Create Subscriptions (or skip for testing)
2. **Step 2**: Deploy Everything Else (user setup, resources, cost management, automation)

---

## Scenario

You are the tenant admin for `contoso.com`. You need to provision sandbox environments for 2 AI researchers: **Alice** and **Bob**.

---

## Before You Begin: Install Tools and Log In

If you haven't done this yet, follow the [Admin Connection Guide](admin-connection-guide.md) to:
1. Install Azure CLI, PowerShell 7, and Bicep
2. Log in to Azure
3. Verify your permissions

```bash
# Quick check — run these to verify
az account show --query "{User:user.name, Tenant:tenantId}" -o table
az ad user list --top 1 -o table
az bicep version
```

---

## Prepare the Input File

Clone the repository and edit the input file:

```bash
git clone https://github.com/RaikHerrmann/azure-user-provisioning.git
cd azure-user-provisioning
```

Edit `input/users.csv` with your users:

```csv
UserPrincipalName,DisplayName,Email,Department,CostCenter,SubscriptionId
alice.researcher@contoso.com,Alice Researcher,alice.researcher@contoso.com,AI Research,CC-2001,
bob.scientist@contoso.com,Bob Scientist,bob.scientist@contoso.com,AI Research,CC-2002,
```

> **The `SubscriptionId` column is empty** — it will be filled in during Step 1 (or you fill it manually for testing).

### Do the users exist in Entra ID?

Check if your users already have accounts:

```bash
az ad user show --id alice.researcher@contoso.com --query "{Name:displayName, Id:id}" -o table
```

**If users do NOT exist yet**, create them first:

```powershell
cd scripts
pwsh ./New-TenantUsers.ps1 -InputFile "../input/users.csv"
```

This creates the accounts and saves temporary passwords to `output/new-users-*.csv`.

---

## STEP 1: Create Subscriptions

> **For testing: SKIP this step.** Add your existing subscription ID to the `SubscriptionId` column in the CSV instead. Jump to [Step 2](#step-2-deploy-everything-else).

### What this step does

Creates one Azure subscription per user, all under the **same billing account**. This ensures centralized billing and cost visibility.

### Find your billing scope

You need your billing scope string. Run these commands to find it:

```bash
# List billing accounts
az billing account list --query "[].{Name:name, DisplayName:displayName, Type:agreementType}" -o table
```

**For Microsoft Customer Agreement (MCA):**
```bash
# List billing profiles
az billing profile list --account-name "YOUR_BILLING_ACCOUNT" -o table

# List invoice sections
az billing invoice section list --account-name "YOUR_BILLING_ACCOUNT" --profile-name "YOUR_PROFILE" -o table
```

Your billing scope is:
```
/providers/Microsoft.Billing/billingAccounts/ACCOUNT_ID/billingProfiles/PROFILE_ID/invoiceSections/SECTION_ID
```

**For Enterprise Agreement (EA):**
```bash
# The billing scope is:
/providers/Microsoft.Billing/billingAccounts/ACCOUNT_ID/enrollmentAccounts/ENROLLMENT_ID
```

### Run subscription creation

```powershell
cd scripts

# Preview first (dry run)
pwsh ./New-UserSubscriptions.ps1 `
    -InputFile "../input/users.csv" `
    -BillingScope "/providers/Microsoft.Billing/billingAccounts/XXXX/billingProfiles/XXXX/invoiceSections/XXXX" `
    -WhatIf

# Create subscriptions
pwsh ./New-UserSubscriptions.ps1 `
    -InputFile "../input/users.csv" `
    -BillingScope "/providers/Microsoft.Billing/billingAccounts/XXXX/billingProfiles/XXXX/invoiceSections/XXXX"
```

**What happens:**
- A subscription named "Sandbox - Alice Researcher" is created under your billing account
- A subscription named "Sandbox - Bob Scientist" is created under the same billing account
- An updated input file is saved to `output/users-with-subscriptions-*.csv` with the subscription IDs filled in

**Use the updated file for Step 2:**
```powershell
# The script tells you the output file path. Use that for the next step.
```

---

## STEP 2: Deploy Everything Else

This is where the actual environment provisioning happens. It deploys **six phases** for each user: prerequisites check, input parsing, identity resolution, provider registration, Bicep deployment, and summary.

### What this step creates (for each user)

| Component | What It Is | Why |
|-----------|-----------|-----|
| **Resource Group** | A container for the user's resources (`rg-alice-researcher-contoso-com`) | Isolation boundary |
| **RBAC Assignment** | Sandbox Contributor role scoped to the RG | User can work inside their RG, but can't escape |
| **Azure Policy** | Naming convention guardrail (`rg-*`) | Extra safety layer |
| **AI Foundry Hub + Project** | Azure AI workspace with storage, key vault, monitoring | For AI/ML experiments |
| **Budget** | Monthly budget ($20) with thresholds at 75%, 90%, and 100% | Cost monitoring |
| **Action Groups** | Email notifications for warnings and enforcement | Alerts |
| **Automation Account** | Runbooks that enforce cost limits automatically | Cost enforcement engine |
| **Webhook** | Connects the budget notification to the automation runbook | Trigger chain |
| **Daily Schedule** | Backup check at 06:00 UTC every day | Redundant enforcement |

### Option A: Test with a Single User (Recommended First Time)

```powershell
cd scripts

# Use the file from Step 1, or your original file with SubscriptionId filled in
pwsh ./Deploy-UserEnvironment.ps1 `
    -InputFile "../input/users.csv" `
    -Location "swedencentral" `
    -SingleUser "alice.researcher@contoso.com" `
    -Step
```

**What `-Step` does:** Pauses after each phase so you can inspect the results:

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
  → Validating Bicep templates...
  ✓ Bicep templates valid

  Next: Read and validate input file
  Press ENTER to continue, or 'q' to quit:
```

Press **ENTER** at each pause to continue, or type **q** to stop.

### Option B: Preview Without Deploying (What-If)

```powershell
pwsh ./Deploy-UserEnvironment.ps1 `
    -InputFile "../input/users.csv" `
    -Location "swedencentral" `
    -WhatIf
```

This shows exactly what *would* be created, without actually creating anything. Great for review.

### Option C: Deploy All Users at Once

```powershell
pwsh ./Deploy-UserEnvironment.ps1 `
    -InputFile "../input/users.csv" `
    -Location "swedencentral"
```

This deploys all users sequentially. Each user takes 5-15 minutes.

---

## Understanding Each Phase of Step 2

### Phase 1: Prerequisites

**What it does:** Checks that Azure CLI, Bicep, and authentication are working. Validates the Bicep templates compile correctly.

**What can go wrong:** If you're not logged in, it tells you to run `az login`. If Bicep isn't installed, it auto-installs it.

### Phase 2: Input Parsing

**What it does:** Reads your CSV/JSON file and lists the users to process. If you used `-SingleUser`, it filters to just that one user.

**What can go wrong:** If the file has wrong column names or the user doesn't exist in the file.

### Phase 3: Identity Resolution

**What it does:** For each user in the input file, it looks up their **Object ID** in Entra ID (Azure's identity service). The Object ID is a unique identifier Azure uses internally.

**What can go wrong:** If a user doesn't exist in Entra ID, they're skipped with a warning. Use `New-TenantUsers.ps1` to create missing users.

### Phase 4: Resource Provider Registration

**What it does:** Ensures the required Azure services are enabled for your subscription. Azure has many services (called "resource providers"), and some need to be registered before use.

Examples of providers being registered:
- `Microsoft.MachineLearningServices` (for AI Foundry)
- `Microsoft.Automation` (for cost enforcement runbooks)
- `Microsoft.Consumption` (for budget monitoring)

**What can go wrong:** Usually nothing — this step is automatic. If you lack permissions, the script warns you.

### Phase 5: Bicep Deployment (The Main Event)

**What it does:** For each user, it runs the Bicep template which creates:

1. **Resource Group** (`rg-alice-researcher-contoso-com`)
   - This is the user's isolated container

2. **RBAC Setup** — assigns two roles:
   - **Sandbox Contributor** → the user (can create/manage resources, but NOT modify cost controls)
   - **Owner** → the admin (full control for management)

3. **Azure Policy** — naming convention guardrail at subscription scope

4. **AI Foundry** — Hub + Project + Storage + Key Vault + App Insights + Log Analytics

5. **Cost Management:**
   - Budget with $15 warning / $20 hard limit
   - Action Group for email notifications

6. **Automation Account:**
   - Runbook: `Invoke-CostEnforcement` (changes user to read-only, stops resources)
   - Runbook: `Invoke-GracePeriodCleanup` (deletes resources after grace period)
   - Schedule: Daily check at 06:00 UTC (backup enforcement)
   - Managed Identity with Contributor + User Access Administrator roles

After Bicep deployment, the script:
- **Uploads the PowerShell runbook code** to the Automation Account
- **Creates a webhook** so the budget notification can trigger the runbook
- **Wires the webhook to the Action Group** so the trigger chain is complete

**What can go wrong:**
- AI Foundry deployment fails → check that your region supports it (try `swedencentral` or `eastus`)
- RBAC assignment fails → you need Owner permissions
- Webhook wiring fails → non-fatal, the daily schedule provides backup enforcement

### Phase 6: Summary

**What it does:** Shows a table of results (SUCCESS/FAILED for each user) and saves everything to log files.

---

## Verify the Deployment Worked

After deployment, run these checks:

### Check Resource Groups

```bash
az group list --query "[?tags.ManagedBy=='IaC-Automation']" -o table
```

Expected:
```
Name                                  Location       Status
------------------------------------  -------------  ---------
rg-alice-researcher-contoso-com       swedencentral  Succeeded
rg-bob-scientist-contoso-com          swedencentral  Succeeded
```

### Check Alice's Permissions

```bash
az role assignment list \
    --assignee "alice.researcher@contoso.com" \
    --all \
    --query "[].{Role:roleDefinitionName, Scope:scope}" -o table
```

Expected — she has Sandbox Contributor on her RG, AI Developer on her Hub:
```
Role                                Scope
----------------------------------  --------------------------------------------------
Sandbox Contributor - xxxxx         /subscriptions/.../resourceGroups/rg-alice-...
Azure AI Developer                  /subscriptions/.../workspaces/aihub-xxxxx
Cognitive Services OpenAI User      /subscriptions/.../workspaces/aihub-xxxxx
```

### Verify Alice CANNOT Create Resource Groups

If you can authenticate as Alice (for testing):
```bash
az login --username alice.researcher@contoso.com

# This should FAIL:
az group create --name "rg-forbidden-test" --location swedencentral
# Expected error: The user does not have authorization to perform action
# 'Microsoft.Resources/subscriptions/resourceGroups/write'
```

### Verify Alice CANNOT Delete the Automation Account

```bash
# As Alice — this should FAIL:
az automation account delete --resource-group "rg-alice-researcher-contoso-com" --name "aa-cost-XXXXX"
# Expected error: does not have authorization to perform action
# 'Microsoft.Automation/automationAccounts/delete'
```

### Check Budget

```bash
az consumption budget list \
    --resource-group "rg-alice-researcher-contoso-com" \
    --query "[].{Name:name, Amount:amount}" -o table
```

Expected: Budget with amount 20 (the hard limit).

---

## What Happens When Costs Exceed the Limit

Here's a timeline of what happens automatically:

```
Day 1-10:  Alice deploys models, runs experiments freely
           (She has Sandbox Contributor — full resource access)

Day 11:    Cost reaches $15 → Alice receives WARNING EMAIL
           (No action taken, just informational)

Day 13:    Cost reaches $20 → ENFORCEMENT TRIGGERS:
           ✓ Automation runbook starts
           ✓ Alice's role: Sandbox Contributor → Reader (read-only)
           ✓ All VMs, Web Apps, Function Apps: STOPPED
           ✓ ML inference endpoints: DISABLED
           ✓ Alice receives enforcement email
           ✓ 5-day grace period begins

Day 13-18: Alice can VIEW resources but CANNOT modify anything
           (Reader role is read-only)

Day 18:    Grace period expires → CLEANUP RUNBOOK:
           ✓ All resources in rg-alice-researcher-contoso-com: DELETED
           ✓ All RBAC assignments: REMOVED
           ✓ Alice receives final notification

After:     Admin can re-provision Alice's environment at any time
           by re-running the deploy script
```

### Daily Backup Check (06:00 UTC)

Even if the budget notification is delayed or the webhook fails, the daily scheduled runbook queries the Cost Management API directly. If costs exceed the hard limit, enforcement runs automatically. This means enforcement happens within **at most 24 hours** of exceeding the limit.

---

## Customize Budget Thresholds

Deploy with different values:

```powershell
pwsh ./Deploy-UserEnvironment.ps1 `
    -InputFile "../input/users.csv" `
    -Location "westeurope" `
    -WarningBudget 10 `
    -HardLimitBudget 15 `
    -GracePeriodDays 3
```

This sets:
- Warning emails at $10
- Hard enforcement at $15
- Resources deleted 3 days after enforcement (instead of 5)

---

## Cleanup: Remove a User's Environment

### Remove One User

```powershell
pwsh ./scripts/Remove-UserEnvironment.ps1 `
    -UserPrincipalName "alice.researcher@contoso.com" `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

This removes: policies, RBAC, the resource group (and all resources inside), and deployment history.

### Remove All Users

```powershell
$subId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
Import-Csv "./input/users.csv" | ForEach-Object {
    pwsh ./scripts/Remove-UserEnvironment.ps1 `
        -UserPrincipalName $_.UserPrincipalName `
        -SubscriptionId $subId `
        -Force
}
```

---

## Quick Reference: Testing Without New Subscriptions

If you **cannot create new subscriptions** (common for testing), here's the shortcut:

1. **Skip Step 1 entirely**
2. Edit `input/users.csv` and put your existing subscription ID in the `SubscriptionId` column:
   ```csv
   UserPrincipalName,DisplayName,Email,Department,CostCenter,SubscriptionId
   alice.researcher@contoso.com,Alice Researcher,alice.researcher@contoso.com,AI Research,CC-2001,xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   bob.scientist@contoso.com,Bob Scientist,bob.scientist@contoso.com,AI Research,CC-2002,xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```
3. Run Step 2 directly:
   ```powershell
   pwsh ./scripts/Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -SingleUser "alice.researcher@contoso.com" -Step
   ```

This deploys both users into the **same subscription** with separate resource groups. The RBAC scoping still ensures each user can only access their own RG.

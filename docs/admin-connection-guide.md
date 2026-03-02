# Admin Connection Guide

How to connect to Azure before running the provisioning scripts. This guide assumes you are new to Azure and walks you through each step.

---

## Table of Contents

- [What You Need Before Starting](#what-you-need-before-starting)
- [Key Azure Concepts](#key-azure-concepts)
- [Step 1: Install the Tools](#step-1-install-the-tools)
- [Step 2: Log In to Azure](#step-2-log-in-to-azure)
- [Step 3: Find and Select Your Subscription](#step-3-find-and-select-your-subscription)
- [Step 4: Verify Everything Works](#step-4-verify-everything-works)
- [Advanced: Service Principal for CI/CD](#advanced-service-principal-for-cicd)
- [Required Permissions (Reference)](#required-permissions-reference)
- [Troubleshooting](#troubleshooting)

---

## What You Need Before Starting

You need **three things** to run this solution:

| What | Why | How to Get It |
|------|-----|--------------|
| **Azure Tenant** | Your organization's identity directory | Your IT admin creates this, or use an existing one |
| **Azure Subscription** | Where resources (and costs) live | Use an existing one — all user environments deploy as resource groups within it |
| **Admin Permissions** | You need Owner or Global Admin access | Ask your IT admin, or if it's your personal tenant, you already have this |

---

## Key Azure Concepts

If you're new to Azure, here's a quick glossary of terms used in this solution:

| Term | What It Means | Analogy |
|------|--------------|---------|
| **Tenant** | Your organization's Azure identity directory (Entra ID). Contains all user accounts. | Like your company's employee directory |
| **Subscription** | A billing container for Azure resources. Think of it as a "cost bucket." | Like a department credit card |
| **Resource Group** | A folder that contains related Azure resources (VMs, storage, etc.). | Like a project folder on your computer |
| **RBAC** | Role-Based Access Control — who can do what, and where. | Like file permissions on a shared drive |
| **Bicep** | Microsoft's language for defining Azure infrastructure as code. Like a blueprint for buildings. | Like a recipe — declares what to create |
| **Azure CLI** | Command-line tool to manage Azure. You type commands, Azure executes them. | Like a remote control for Azure |
| **Entra ID** | Microsoft's identity service (formerly Azure AD). Manages user accounts and authentication. | Like Active Directory for the cloud |
| **Managed Identity** | An automatic identity Azure creates for a resource, so it can authenticate without passwords. | Like a keycard for a robot employee |

---

## Step 1: Install the Tools

You need three tools installed on your computer. Open a terminal (PowerShell on Windows, Terminal on Mac/Linux) and run these commands:

### 1a. Install Azure CLI

**Windows** (open PowerShell as Administrator):
```powershell
winget install Microsoft.AzureCLI
```

**Mac**:
```bash
brew install azure-cli
```

**Linux**:
```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

**Verify it works:**
```bash
az version
```
You should see a version number like `2.67.0` or higher.

### 1b. Install PowerShell 7

**Windows**:
```powershell
winget install Microsoft.PowerShell
```

**Mac**:
```bash
brew install powershell/tap/powershell
```

**Verify it works:**
```bash
pwsh --version
```
You should see `PowerShell 7.4` or higher.

### 1c. Install Bicep (Automatic)

Bicep is auto-installed with the Azure CLI. Verify with:
```bash
az bicep version
```

If it's missing, install manually:
```bash
az bicep install
```

---

## Step 2: Log In to Azure

### Find Your Tenant ID

1. Go to [https://portal.azure.com](https://portal.azure.com)
2. In the top-right corner, click your profile icon
3. Click **"Switch directory"**
4. Your current tenant name and **Tenant ID** (a GUID like `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) are shown

### Log In via Terminal

```bash
az login --tenant YOUR_TENANT_ID
```

> **Replace** `YOUR_TENANT_ID` with the actual ID you found above.

A browser window will open. Sign in with your admin account (the account that has Owner permissions on the tenant).

After signing in, the terminal will show your available subscriptions:
```
A]  Subscription 1 (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
B]  Subscription 2 (yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy)
```

**What if no browser opens?** Use device code login instead:
```bash
az login --tenant YOUR_TENANT_ID --use-device-code
```
This gives you a code to enter at [https://microsoft.com/devicelogin](https://microsoft.com/devicelogin).

---

## Step 3: Find and Select Your Subscription

After logging in, you need to tell Azure which subscription to use.

### List Your Subscriptions

```bash
az account list --output table
```

This shows all subscriptions you have access to:
```
Name                    SubscriptionId                        State     IsDefault
----------------------  ------------------------------------  --------  ---------
My Subscription         xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  Enabled   True
Dev/Test Subscription   yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy  Enabled   False
```

### Set the Active Subscription

```bash
az account set --subscription "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

> **Replace** the ID with your actual subscription ID from the table above.

### For Testing

All user environments are deployed as resource groups within the admin's active subscription. Set it with:
```bash
az account set --subscription "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

---

## Step 4: Verify Everything Works

Run these commands one by one to make sure everything is set up correctly:

```bash
# 1. Check who you're logged in as
az account show --query "{Name:name, Subscription:id, Tenant:tenantId, User:user.name}" -o table
```
**Expected**: You see your admin username, subscription ID, and tenant ID.

```bash
# 2. Check you can read users from Entra ID
az ad user list --top 3 --query "[].{UPN:userPrincipalName, Name:displayName}" -o table
```
**Expected**: You see a list of users. If you get "Insufficient privileges", see [Troubleshooting](#troubleshooting).

```bash
# 3. Check Bicep templates compile correctly
az bicep build --file infra/main.bicep --stdout > $null
echo "Bicep OK"
```
**Expected**: You see "Bicep OK" with no errors.

```bash
# 4. Check your admin permissions
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --all --query "[].{Role:roleDefinitionName, Scope:scope}" -o table
```
**Expected**: You should see **Owner** or **Contributor + User Access Administrator** at the subscription level.

If all four checks pass, you're ready to run the deployment. See [Sample Walkthrough](sample-walkthrough.md).

---

## Advanced: Service Principal for CI/CD

> **Skip this section** if you're running scripts manually (interactive login above is sufficient).

For automated pipelines (GitHub Actions, Azure DevOps), you need a service principal.

### Create a Service Principal

```bash
az ad sp create-for-rbac \
  --name "sp-user-provisioning" \
  --role Owner \
  --scopes "/subscriptions/YOUR_SUBSCRIPTION_ID"
```

Save the output — you'll need the `appId`, `password`, and `tenant`:
```json
{
  "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "password": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "tenant": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

### Grant Microsoft Graph Permissions

```bash
# Allow the SP to read user identities
az ad app permission add \
  --id "YOUR_APP_ID" \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Role

az ad app permission admin-consent --id "YOUR_APP_ID"
```

### For GitHub Actions (OIDC — No Secrets)

```bash
az ad app federated-credential create \
  --id "YOUR_APP_ID" \
  --parameters '{
    "name": "github-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:YOUR_ORG/azure-user-provisioning:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

Add these to your GitHub repository secrets:
- `AZURE_CLIENT_ID` = appId
- `AZURE_TENANT_ID` = tenant
- `AZURE_SUBSCRIPTION_ID` = your subscription ID

---

## Required Permissions (Reference)

### For Interactive Login (Manual Runs)

| Permission | Why You Need It |
|------------|----------------|
| **Subscription Owner** | Create resource groups, deploy resources, manage RBAC |
| **Entra ID read access** | Resolve user Object IDs from their email addresses (UPNs) |

> **How to check**: Run `az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --all -o table` and look for "Owner" at the subscription scope.

### For Service Principal (CI/CD)

| Role | Scope | Why |
|------|-------|-----|
| **Owner** | Subscription | Full resource + RBAC management |
| **Microsoft Graph: User.Read.All** | Application | Resolve user identities |

---

## Troubleshooting

### "Insufficient privileges" when listing users

**Problem**: `az ad user list` returns an authorization error.

**Solution**: Your account needs permission to read Entra ID users. For interactive login, this is usually automatic for admin accounts. If not:
1. Go to Azure Portal → Microsoft Entra ID → Roles and administrators
2. Ensure you have "Global Reader" or "User Administrator" role

### "Authorization_RequestDenied"

**Problem**: Service principal can't read user data.

**Solution**:
```bash
az ad app permission add --id YOUR_APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Role
az ad app permission admin-consent --id YOUR_APP_ID
```

### "The subscription is not registered to use namespace..."

**Problem**: Resource provider not registered.

**Solution**: The deployment script registers providers automatically. To do it manually:
```bash
az provider register --namespace Microsoft.MachineLearningServices
az provider register --namespace Microsoft.CognitiveServices
```

### Deploying to the wrong tenant

**Problem**: Resources appear in a different tenant than expected.

**Solution**: Always specify the tenant explicitly:
```bash
az login --tenant YOUR_TENANT_ID
az account show  # Verify tenant ID matches
```

### Token expired during long deployments

**Problem**: Authentication token expires during a 10-20 minute deployment.

**Solution**: Re-login and re-run:
```bash
az login --tenant YOUR_TENANT_ID
# Re-run the deployment script — it is idempotent (safe to re-run)
```

### "User not found in Entra ID"

**Problem**: Users in your input file don't exist in the tenant.

**Solution**: Either:
1. Create users manually in Azure Portal → Microsoft Entra ID → Users → New user
2. Use the optional `New-TenantUsers.ps1` script:
   ```powershell
   pwsh ./scripts/New-TenantUsers.ps1 -InputFile "./input/users.csv"
   ```

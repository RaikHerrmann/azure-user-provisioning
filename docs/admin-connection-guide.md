# Admin Connection Guide

This document explains how a tenant administrator should connect to Azure before running the provisioning scripts.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Option 1: Interactive Login (Recommended for Manual Runs)](#option-1-interactive-login-recommended-for-manual-runs)
- [Option 2: Service Principal (Recommended for CI/CD)](#option-2-service-principal-recommended-for-cicd)
- [Option 3: Managed Identity (Azure-hosted Automation)](#option-3-managed-identity-azure-hosted-automation)
- [Verifying Your Connection](#verifying-your-connection)
- [Required Permissions](#required-permissions)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Tool | Install |
|------|---------|
| **Azure CLI** ≥ 2.60 | `winget install Microsoft.AzureCLI` or [https://aka.ms/installazurecli](https://aka.ms/installazurecli) |
| **PowerShell** ≥ 7.4 | `winget install Microsoft.PowerShell` |
| **Bicep CLI** | Installed automatically with Azure CLI (`az bicep install`) |

---

## Option 1: Interactive Login (Recommended for Manual Runs)

Use this when running scripts manually from your workstation.

### Step 1: Login to Azure

```bash
# Login with a specific tenant
az login --tenant YOUR_TENANT_ID

# If you have access to multiple tenants, specify the tenant:
az login --tenant contoso.onmicrosoft.com
```

A browser window opens. Sign in with your **tenant admin** credentials.

### Step 2: Select Subscription

```bash
# List available subscriptions
az account list --output table

# Set the default subscription (or a "management" subscription)
az account set --subscription "YOUR_SUBSCRIPTION_ID"
```

### Step 3: Verify

```bash
az account show --output table
```

You should see your admin account and the correct tenant.

### Step 4: Run the Deployment

```powershell
cd scripts
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -Location "swedencentral"
```

> **Note**: The script will automatically resolve your admin identity and use it
> for the `tenantAdminObjectId` parameter.

---

## Option 2: Service Principal (Recommended for CI/CD)

Use this for GitHub Actions, Azure DevOps, or other automated pipelines.

### Step 1: Create a Service Principal

```bash
# Create SP with Owner role at subscription scope
az ad sp create-for-rbac \
  --name "sp-user-provisioning" \
  --role Owner \
  --scopes "/subscriptions/YOUR_SUBSCRIPTION_ID"
```

Save the output:
```json
{
  "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",      ← CLIENT_ID
  "displayName": "sp-user-provisioning",
  "password": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",       ← CLIENT_SECRET
  "tenant": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"        ← TENANT_ID
}
```

### Step 2: Grant Additional Permissions

The service principal needs these permissions:

```bash
SP_OBJECT_ID=$(az ad sp show --id "YOUR_APP_ID" --query id -o tsv)

# User Access Administrator (to manage RBAC)
az role assignment create \
  --assignee-object-id $SP_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --role "User Access Administrator" \
  --scope "/subscriptions/YOUR_SUBSCRIPTION_ID"

# Microsoft Graph permissions (to read user identities)
az ad app permission add \
  --id "YOUR_APP_ID" \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Role
# ^ User.Read.All (Application permission)

# Grant admin consent
az ad app permission admin-consent --id "YOUR_APP_ID"
```

### Step 3: Login as Service Principal

```bash
az login --service-principal \
  --username "YOUR_APP_ID" \
  --password "YOUR_CLIENT_SECRET" \
  --tenant "YOUR_TENANT_ID"
```

### Step 4: For GitHub Actions (OIDC — Recommended)

Instead of storing secrets, use federated credentials:

```bash
# Create federated credential for GitHub Actions
az ad app federated-credential create \
  --id "YOUR_APP_ID" \
  --parameters '{
    "name": "github-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:YOUR_ORG/azure-user-provisioning:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

Then in your GitHub repository secrets:
- `AZURE_CLIENT_ID` = App (client) ID
- `AZURE_TENANT_ID` = Directory (tenant) ID
- `AZURE_SUBSCRIPTION_ID` = Subscription ID

The GitHub Actions workflow uses `azure/login@v2` with OIDC — no secrets stored.

---

## Option 3: Managed Identity (Azure-hosted Automation)

If running from an Azure VM, Azure Automation, or Azure Container Instance:

```bash
# Login with system-assigned managed identity
az login --identity

# Login with a specific user-assigned managed identity
az login --identity --username "YOUR_MI_CLIENT_ID"
```

> **Note**: Ensure the managed identity has the required roles assigned
> at the subscription scope.

---

## Verifying Your Connection

After logging in, run these checks:

```bash
# 1. Verify identity
az account show --query "{Name:name, Subscription:id, Tenant:tenantId, User:user.name}" -o table

# 2. Verify admin permissions
az role assignment list --assignee "YOUR_PRINCIPAL_ID" --all --output table

# 3. Verify Entra ID access (can read users)
az ad user list --top 5 --query "[].{UPN:userPrincipalName, Name:displayName}" -o table

# 4. Verify Azure CLI and Bicep versions
az version
az bicep version

# 5. Test Bicep compilation
az bicep build --file infra/main.bicep --stdout > /dev/null && echo "Bicep OK"
```

---

## Required Permissions

### For the Admin (Interactive Login)

| Permission | Why |
|------------|-----|
| **Subscription Owner** | Create resource groups, deploy resources, manage RBAC |
| **User Access Administrator** | Assign roles to users and service principals |
| **Entra ID User.Read.All** | Resolve user Object IDs from UPNs |
| **Policy Contributor** | Create and assign Azure Policies |

### For the Service Principal (CI/CD)

| Role | Scope | Why |
|------|-------|-----|
| **Owner** | Subscription | Full resource + RBAC management |
| **User Access Administrator** | Subscription | Manage RBAC assignments |
| **Microsoft Graph: User.Read.All** | Application | Resolve user identities |

### For Custom Role Creation

Custom roles (`Sandbox User - No RG Create`) require `Microsoft.Authorization/roleDefinitions/write`
at the subscription scope. This is included in **Owner** and **User Access Administrator**.

---

## Troubleshooting

### "Insufficient privileges"

```bash
# Check what roles you have
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --all -o table
```

You need **Owner** or **Contributor + User Access Administrator** at the subscription level.

### "User not found in Entra ID"

The users in your input file must already exist in the tenant. Either:
1. Create them manually in the Azure Portal (Entra ID → Users → New user)
2. Use the optional `New-TenantUsers.ps1` script:
   ```powershell
   pwsh ./scripts/New-TenantUsers.ps1 -InputFile "./input/users.csv"
   ```

### "Authorization_RequestDenied" when reading users

Your account needs Microsoft Graph permissions. For interactive login, this is
usually automatic. For service principals, run:
```bash
az ad app permission add --id YOUR_APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Role
az ad app permission admin-consent --id YOUR_APP_ID
```

### "Multiple tenants" — deploying to wrong tenant

Always specify the tenant explicitly:
```bash
az login --tenant YOUR_TENANT_ID
az account show  # verify before deploying
```

### "Token expired" during long deployments

Deployments can take 10-20 minutes. If your token expires:
```bash
az login --tenant YOUR_TENANT_ID  # re-login
# Then re-run the deployment script — it's idempotent
```

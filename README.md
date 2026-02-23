# Azure User Sandbox Provisioning

Automated Infrastructure-as-Code solution for provisioning per-user Azure sandbox environments with AI Foundry, cost controls, and automated enforcement.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Detailed Setup](#detailed-setup)
- [Input File Format](#input-file-format)
- [What Gets Deployed](#what-gets-deployed)
- [Cost Management](#cost-management)
- [Security Model](#security-model)
- [Customization](#customization)
- [Cleanup](#cleanup)
- [CI/CD with GitHub Actions](#cicd-with-github-actions)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

---

## Overview

This solution enables a tenant administrator to repeatably provision isolated Azure sandbox environments for multiple users from a simple CSV or JSON input file. Each user receives:

| Feature | Description |
|---------|-------------|
| **Subscription** | Dedicated subscription (or shared, configurable) |
| **Resource Group** | Pre-created default RG; user cannot create additional RGs |
| **AI Foundry** | Azure AI Hub + Project with storage, Key Vault, and monitoring |
| **RBAC** | Contributor within their RG; policy-restricted from creating new RGs |
| **Cost Monitoring** | $15 warning email, $20 hard enforcement |
| **Auto-Enforcement** | Account set to read-only, resources stopped, 5-day grace period then deletion |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Tenant Admin Workflow                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────┐    ┌──────────────────┐    ┌──────────────────────┐  │
│  │ Input    │───▶│ PowerShell       │───▶│ Bicep Deployment     │  │
│  │ CSV/JSON │    │ Orchestrator     │    │ (per user)           │  │
│  └──────────┘    └──────────────────┘    └──────────────────────┘  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Per-User Azure Environment                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─── Subscription ──────────────────────────────────────────────┐  │
│  │                                                               │  │
│  │  ┌─── Resource Group (rg-{user}) ───────────────────────────┐│  │
│  │  │                                                          ││  │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   ││  │
│  │  │  │ AI Foundry   │  │ Key Vault    │  │ Storage      │   ││  │
│  │  │  │ Hub + Project│  │              │  │ Account      │   ││  │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘   ││  │
│  │  │                                                          ││  │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   ││  │
│  │  │  │ App Insights │  │ Log          │  │ Automation   │   ││  │
│  │  │  │              │  │ Analytics    │  │ Account      │   ││  │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘   ││  │
│  │  │                                                          ││  │
│  │  └──────────────────────────────────────────────────────────┘│  │
│  │                                                               │  │
│  │  ┌─── Subscription-Level ────────────────────────────────────┐│  │
│  │  │  • Azure Policy (deny extra RG creation)                  ││  │
│  │  │  • Budget ($15 warn / $20 enforce)                        ││  │
│  │  │  • Action Groups (email + automation webhook)             ││  │
│  │  └───────────────────────────────────────────────────────────┘│  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

         ┌─────────────────────────────────────────────┐
         │          Cost Enforcement Flow               │
         ├─────────────────────────────────────────────┤
         │                                             │
         │  $15 reached ──▶ Warning email to user      │
         │                                             │
         │  $20 reached ──▶ Automation Runbook:        │
         │                  1. RBAC ─▶ Reader (R/O)    │
         │                  2. Stop all resources      │
         │                  3. Email notification       │
         │                  4. Schedule 5-day cleanup   │
         │                                             │
         │  +5 days ──────▶ Cleanup Runbook:           │
         │                  1. Delete all resources     │
         │                  2. Remove RBAC              │
         │                  3. Final notification       │
         └─────────────────────────────────────────────┘
```

## Prerequisites

### Software Requirements

| Tool | Version | Purpose |
|------|---------|---------|
| [Azure CLI](https://aka.ms/installazurecli) | ≥ 2.60 | Azure management |
| [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) | ≥ 0.28 | IaC compilation (auto-installed with Azure CLI) |
| PowerShell | ≥ 7.4 | Orchestration scripts |
| Git | ≥ 2.0 | Version control |

### Azure Requirements

| Requirement | Details |
|-------------|---------|
| **Tenant Admin** | Global Administrator or Subscription Owner role |
| **Billing Access** | EA Enrollment Account or MCA Billing Profile (for new subscription creation) |
| **Entra ID** | Users must exist in the tenant before provisioning |
| **Resource Providers** | `Microsoft.MachineLearningServices`, `Microsoft.CognitiveServices`, `Microsoft.Automation` must be registered |

### Register Required Resource Providers

```bash
az provider register --namespace Microsoft.MachineLearningServices
az provider register --namespace Microsoft.CognitiveServices
az provider register --namespace Microsoft.Automation
az provider register --namespace Microsoft.Consumption
az provider register --namespace Microsoft.Insights
az provider register --namespace Microsoft.PolicyInsights
```

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/YOUR-ORG/azure-user-provisioning.git
cd azure-user-provisioning

# 2. Login to Azure as tenant admin
az login --tenant YOUR_TENANT_ID

# 3. Edit the input file with your users
# Edit input/users.csv or input/users.json

# 4. Run the provisioning script
cd scripts
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -Location "swedencentral"

# 5. (Optional) Preview changes first
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -WhatIf
```

## Detailed Setup

### Step 1: Configure Input File

Create your user list in CSV or JSON format:

**CSV Format** (`input/users.csv`):
```csv
UserPrincipalName,DisplayName,Email,Department,CostCenter
john.doe@contoso.com,John Doe,john.doe@contoso.com,Engineering,CC-1001
jane.smith@contoso.com,Jane Smith,jane.smith@contoso.com,Data Science,CC-1002
```

**JSON Format** (`input/users.json`):
```json
{
  "users": [
    {
      "userPrincipalName": "john.doe@contoso.com",
      "displayName": "John Doe",
      "email": "john.doe@contoso.com",
      "department": "Engineering",
      "costCenter": "CC-1001"
    }
  ]
}
```

### Step 2: Subscription Setup

**Option A: Automatic Subscription Creation (EA/MCA)**

If you have Enterprise Agreement or Microsoft Customer Agreement billing access:

```bash
pwsh ./Deploy-UserEnvironment.ps1 \
  -InputFile "../input/users.csv" \
  -BillingAccountName "1234567" \
  -BillingProfileName "xxxx-xxxx" \
  -InvoiceSectionName "yyyy-yyyy"
```

**Option B: Use Existing Subscriptions**

Add `SubscriptionId` column to your CSV:
```csv
UserPrincipalName,DisplayName,Email,Department,CostCenter,SubscriptionId
john.doe@contoso.com,John Doe,john.doe@contoso.com,Engineering,CC-1001,xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Then run with `-SkipSubscriptionCreation`:
```bash
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -SkipSubscriptionCreation
```

### Step 3: Deploy

```bash
# Full deployment
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -Location "swedencentral"

# Customized thresholds
pwsh ./Deploy-UserEnvironment.ps1 \
  -InputFile "../input/users.csv" \
  -Location "westeurope" \
  -WarningBudget 10 \
  -HardLimitBudget 15 \
  -GracePeriodDays 3
```

### Step 4: Verify

After deployment, check results in the `logs/` directory:
- `deployment-{timestamp}.log` — Full deployment transcript
- `results-{timestamp}.csv` — Summary of all user environments

## What Gets Deployed

### Per-User Resources

| Resource | Purpose |
|----------|---------|
| **Resource Group** | `rg-{user-name-sanitized}` — Isolated container for all user resources |
| **Azure AI Hub** | `aihub-{unique}` — AI Foundry workspace for model management |
| **Azure AI Project** | `aiproj-{unique}` — AI project within the hub |
| **Storage Account** | `staifoundry{unique}` — Data storage for AI workloads |
| **Key Vault** | `kv-ai-{unique}` — Secrets management (RBAC-enabled, no key access) |
| **Application Insights** | `appi-ai-{unique}` — Application monitoring |
| **Log Analytics** | `log-ai-{unique}` — Centralized logging |
| **Automation Account** | `aa-cost-{unique}` — Cost enforcement automation |
| **Budget** | Monthly budget with warning and hard limit thresholds |
| **Action Groups** | Email notifications and automation webhooks |
| **Azure Policy** | Deny creation of additional resource groups |

### RBAC Assignments

| Principal | Role | Scope |
|-----------|------|-------|
| User | **Contributor** | Resource Group |
| User | **Azure AI Developer** | AI Foundry Hub |
| User | **Cognitive Services OpenAI User** | AI Foundry Hub |
| Tenant Admin | **Owner** | Resource Group |
| Automation Account (MI) | **Contributor** | Resource Group |

## Cost Management

### Thresholds and Actions

| Threshold | Trigger | Actions |
|-----------|---------|---------|
| **$15** (75% of budget) | Actual cost reaches $15 | Warning email sent to user |
| **90% Forecast** | Forecasted cost reaches 90% | Proactive warning email |
| **$20** (100% of budget) | Actual cost reaches $20 | **Full enforcement** (see below) |

### Enforcement at $20

When the hard limit is reached, the **Invoke-CostEnforcement** runbook executes:

1. **Read-Only Mode**: User's Contributor role is replaced with Reader
2. **Resource Stop**: All VMs, Web Apps, Function Apps are stopped
3. **AI Endpoints Disabled**: ML online endpoints scaled to 0 instances
4. **User Notified**: Email sent explaining the situation
5. **Grace Period Started**: 5-day countdown begins (configurable)

### After Grace Period (Day 5)

The **Invoke-GracePeriodCleanup** runbook executes:

1. **Final Warning**: User receives final notification
2. **Resource Deletion**: All resources in the RG are systematically deleted
3. **RBAC Cleanup**: All role assignments are removed
4. **Audit Log**: Full inventory of deleted resources logged

### Budget Timeline Example

```
Day 1-10: User works normally, costs accumulate
Day 11:   $15 reached → Warning email
Day 13:   $20 reached → Account locked to read-only, resources stopped
Day 13-18: Grace period (5 days) — user can read/view but not modify
Day 18:   All resources deleted, user notified
```

## Security Model

### Principle of Least Privilege

- Users get **Contributor** scoped only to their resource group (not subscription)
- Azure Policy **denies** resource group creation at subscription level
- Key Vault uses **RBAC authorization** (no access policies)
- Storage Account has **shared key access disabled**
- Automation Account uses **System-Assigned Managed Identity**
- No credentials are stored in code or variables (only object IDs)

### Policy Enforcement

The Azure Policy `Deny Resource Group Creation` ensures:
- Users cannot create any resource groups beyond their default one
- The tenant admin (Owner) can manage policies and override when needed
- Non-compliance messages clearly explain the restriction

## Customization

### Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Location` | `swedencentral` | Azure region |
| `WarningBudget` | `15` | Warning email threshold (USD) |
| `HardLimitBudget` | `20` | Enforcement threshold (USD) |
| `GracePeriodDays` | `5` | Days before resource deletion |
| `SubscriptionOfferType` | `MS-AZR-0017P` | Offer type for new subscriptions |

### Adding More Resources

To add additional resources to each user's environment, modify `infra/modules/aiFoundry.bicep` or create new Bicep modules and reference them in `infra/main.bicep`.

### Changing AI Foundry Configuration

Edit `infra/modules/aiFoundry.bicep` to:
- Add Azure OpenAI connections
- Deploy specific model endpoints
- Configure container registry
- Adjust SKU tiers

## Cleanup

### Remove a Single User Environment

```bash
pwsh ./scripts/Remove-UserEnvironment.ps1 \
  -UserPrincipalName "john.doe@contoso.com" \
  -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Remove All Environments (Batch)

```bash
# Process all users from the input file
$users = Import-Csv "./input/users.csv"
foreach ($user in $users) {
    pwsh ./scripts/Remove-UserEnvironment.ps1 \
      -UserPrincipalName $user.UserPrincipalName \
      -SubscriptionId $user.SubscriptionId \
      -Force
}
```

## CI/CD with GitHub Actions

The included GitHub Actions workflow (`.github/workflows/provision-users.yml`) enables:

- **Automated provisioning** on push to `main` when input files change
- **Manual trigger** via `workflow_dispatch` with customizable parameters
- **PR preview** with `what-if` validation on pull requests
- **Scheduled runs** (optional) for periodic reconciliation

### Setup

1. Create a Service Principal with appropriate permissions:
   ```bash
   az ad sp create-for-rbac --name "sp-user-provisioning" \
     --role Owner --scopes /providers/Microsoft.Management/managementGroups/YOUR_MG_ID
   ```

2. Add GitHub repository secrets:
   - `AZURE_CLIENT_ID` — Service Principal App ID
   - `AZURE_TENANT_ID` — Azure AD Tenant ID
   - `AZURE_SUBSCRIPTION_ID` — Default Subscription ID
   - `AZURE_CLIENT_SECRET` — Service Principal Secret (or use OIDC)

3. Push changes to trigger the workflow.

## Project Structure

```
azure-user-provisioning/
├── 📁 infra/                          # Bicep IaC templates
│   ├── main.bicep                     # Main orchestrator (subscription scope)
│   └── modules/
│       ├── rbac.bicep                 # RBAC role assignments
│       ├── policy.bicep               # Azure Policy (deny RG creation)
│       ├── aiFoundry.bicep            # AI Foundry Hub + Project + deps
│       ├── budget.bicep               # Budgets + Action Groups
│       └── costEnforcement.bicep      # Automation Account + Runbooks
├── 📁 scripts/                        # PowerShell orchestration
│   ├── Deploy-UserEnvironment.ps1     # Main provisioning script
│   ├── Remove-UserEnvironment.ps1     # Cleanup/teardown script
│   └── runbooks/
│       ├── Invoke-CostEnforcement.ps1 # Budget enforcement runbook
│       └── Invoke-GracePeriodCleanup.ps1  # Grace period cleanup runbook
├── 📁 input/                          # User input files
│   ├── users.csv                      # CSV format (example)
│   └── users.json                     # JSON format (example)
├── 📁 .github/workflows/             # CI/CD
│   └── provision-users.yml            # GitHub Actions workflow
├── 📁 logs/                           # Deployment logs (gitignored)
├── .gitignore
└── README.md                          # This file
```

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `User not found` | User doesn't exist in Entra ID | Create the user first or check UPN |
| `Subscription creation failed` | Missing billing access | Verify EA/MCA enrollment or use existing subscriptions |
| `Policy conflict` | Existing policies interfere | Check `az policy assignment list` |
| `AI Foundry deployment fails` | Region not supported | Use a supported region (swedencentral, eastus, etc.) |
| `Budget not triggering` | Cost data delay | Azure cost data can be delayed 8-24 hours |

### Useful Commands

```bash
# Check deployment status
az deployment sub list --query "[?contains(name,'user-env')]" -o table

# View policy assignments
az policy assignment list --subscription $SUB_ID -o table

# Check budget status
az consumption budget list --subscription $SUB_ID -o table

# View automation job history
az automation job list --automation-account-name $AA_NAME -g $RG_NAME -o table
```

## Contributing

1. Fork this repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Commit changes: `git commit -am 'Add feature'`
4. Push: `git push origin feature/my-change`
5. Create a Pull Request

## License

MIT License — see [LICENSE](LICENSE) for details.

# Azure User Sandbox Provisioning

Automated Infrastructure-as-Code solution for provisioning **per-user Azure sandbox environments** with AI Foundry, cost controls, and automated enforcement.

> **New to Azure?** Start with the [Admin Connection Guide](docs/admin-connection-guide.md) which explains all Azure concepts step by step, then follow the [Sample Walkthrough](docs/sample-walkthrough.md).

---

## What This Solution Does

This solution lets a tenant administrator provision **isolated Azure sandbox environments** for multiple users from a simple CSV or JSON file. Each user receives:

| Feature | Description |
|---------|-------------|
| **Isolated Environment** | Own subscription + resource group — users cannot see or touch each other's resources |
| **AI Foundry** | Azure AI Hub + Project pre-deployed with storage, Key Vault, and monitoring |
| **Tamper-Proof Cost Controls** | $15 warning, $20 hard enforcement — users **cannot** disable or modify these |
| **Automatic Enforcement** | At $20: account goes read-only, resources stop, 5-day grace then automatic deletion |
| **One Billing Account** | All subscriptions created under the same billing account for centralized cost visibility |

See the full [Functional Requirements](docs/functional-requirements.md) for detailed specifications.

---

## Two-Step Deployment

The deployment is split into two distinct steps so you can **test Step 2 independently** without creating new subscriptions.

### Step 1: Create Subscriptions (Skip for Testing)

Creates one Azure subscription per user under your billing account.

```powershell
cd scripts
pwsh ./New-UserSubscriptions.ps1 `
    -InputFile "../input/users.csv" `
    -BillingScope "/providers/Microsoft.Billing/billingAccounts/XXXX/billingProfiles/XXXX/invoiceSections/XXXX"
```

> **For testing:** Skip this step entirely. Just add your existing subscription ID to the `SubscriptionId` column in the CSV file. See [Testing Without New Subscriptions](#testing-without-new-subscriptions).

### Step 2: Deploy Everything Else

Deploys all resources, RBAC, policies, cost management, and automation for each user.

```powershell
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -Location "swedencentral"
```

Each phase of Step 2 is independently comprehensible:

| Phase | What It Does | Can You Inspect It? |
|-------|-------------|-------------------|
| 1. Prerequisites | Checks CLI tools, authentication, Bicep syntax | Yes — pauses with `-Step` |
| 2. Input Parsing | Reads user list from CSV/JSON | Yes |
| 3. Identity Resolution | Looks up each user's Object ID in Entra ID | Yes |
| 4. Provider Registration | Enables required Azure services | Yes |
| 5. Deployment | Creates RG, RBAC, AI Foundry, Budget, Automation | Yes — shows each resource |
| 6. Summary | Shows SUCCESS/FAILED per user, saves logs | Yes |

Use `-Step` to pause between phases and `-SingleUser` to test one user at a time.

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/RaikHerrmann/azure-user-provisioning.git
cd azure-user-provisioning

# 2. Log in as tenant admin
az login --tenant YOUR_TENANT_ID

# 3. Edit the input file with your users
#    (Add SubscriptionId for testing, or run Step 1 first for production)

# 4. Preview changes (what-if — no actual deployment)
cd scripts
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -WhatIf

# 5. Deploy one user for testing
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -SingleUser "john.doe@contoso.com" -Step

# 6. Deploy all users
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -Location "swedencentral"
```

---

## Testing Without New Subscriptions

If you **cannot create new subscriptions** (common during testing), skip Step 1:

1. Find your existing subscription ID:
   ```bash
   az account list --output table
   ```
2. Add it to `input/users.csv`:
   ```csv
   UserPrincipalName,DisplayName,Email,Department,CostCenter,SubscriptionId
   john.doe@contoso.com,John Doe,john.doe@contoso.com,Engineering,CC-1001,YOUR-EXISTING-SUB-ID
   ```
3. Run Step 2 directly:
   ```powershell
   pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -SingleUser "john.doe@contoso.com" -Step
   ```

Multiple users can share a subscription — each gets their own resource group with isolated RBAC.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Admin Workflow                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Step 1 (optional)          Step 2                                  │
│  ┌──────────────────┐       ┌──────────────────────────────────┐   │
│  │ Create            │──────▶│ Deploy Per-User Environments     │   │
│  │ Subscriptions     │       │ (RBAC, AI, Budget, Automation)   │   │
│  │ (billing account) │       │                                  │   │
│  └──────────────────┘       └──────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Per-User Azure Environment                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─── Subscription (under shared billing account) ───────────────┐ │
│  │                                                               │ │
│  │  ┌─── Resource Group (rg-{user}) ───────────────────────────┐ │ │
│  │  │                                                          │ │ │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │ │ │
│  │  │  │ AI Foundry   │  │ Key Vault    │  │ Storage      │   │ │ │
│  │  │  │ Hub + Project│  │ (RBAC auth)  │  │ Account      │   │ │ │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘   │ │ │
│  │  │                                                          │ │ │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │ │ │
│  │  │  │ App Insights │  │ Log          │  │ Automation   │   │ │ │
│  │  │  │              │  │ Analytics    │  │ Account (MI) │   │ │ │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘   │ │ │
│  │  │                Protected from user modification:         │ │ │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │ │ │
│  │  │  │ Budget       │  │ Action       │  │ Automation   │   │ │ │
│  │  │  │ ($15/$20)    │  │ Groups       │  │ Runbooks     │   │ │ │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘   │ │ │
│  │  └──────────────────────────────────────────────────────────┘ │ │
│  │                                                               │ │
│  │  ┌─── Subscription-Level Controls ───────────────────────────┐│ │
│  │  │  • Custom Role: Sandbox Contributor (blocks cost infra)   ││ │
│  │  │  • Azure Policy: Naming convention guardrail (rg-*)       ││ │
│  │  └───────────────────────────────────────────────────────────┘│ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘

         ┌─────────────────────────────────────────────┐
         │         Cost Enforcement Flow                │
         ├─────────────────────────────────────────────┤
         │                                             │
         │  $15 reached ──▶ Warning email to user      │
         │                                             │
         │  $20 reached ──▶ Automation Runbook:        │
         │                  1. RBAC → Reader (R/O)     │
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

---

## Security Model (3 Layers)

| # | Layer | Mechanism | What It Prevents |
|---|-------|-----------|-----------------|
| 1 | **Custom RBAC Role** | Sandbox Contributor (Contributor minus Automation/Budget/ActionGroup) | User cannot disable cost controls |
| 2 | **RBAC Scope** | Role assigned at Resource Group scope only | User cannot create/delete RGs, cannot access other users |
| 3 | **Azure Policy** | Naming convention: `rg-*` only | Additional guardrail against accidental permission expansion |

### What Users CAN Do
- Create, manage, delete resources **within** their resource group
- Use AI Foundry (Hub + Project)
- Access Key Vault via RBAC
- Deploy models, run experiments

### What Users CANNOT Do
- Create or delete resource groups
- Access other users' resource groups
- Modify or delete the Automation Account, Budget, or Action Groups
- Manage RBAC assignments
- Modify subscription-level settings

### RBAC Assignments Per User

| Principal | Role | Scope |
|-----------|------|-------|
| User | **Sandbox Contributor** | Resource Group |
| User | **Azure AI Developer** | AI Foundry Hub |
| User | **Cognitive Services OpenAI User** | AI Foundry Hub |
| Tenant Admin | **Owner** | Resource Group |
| Automation MI | **Contributor** | Resource Group |
| Automation MI | **User Access Administrator** | Resource Group |

---

## Cost Management

| Threshold | Trigger | Action |
|-----------|---------|--------|
| **$15** (75%) | Actual cost ≥ $15 | Warning email to user |
| **90% Forecast** | Forecasted ≥ 90% | Proactive warning email |
| **$20** (100%) | Actual cost ≥ $20 | **Full enforcement** (see below) |

### What Happens at $20

1. User's Sandbox Contributor role → **Reader** (read-only)
2. All VMs, Web Apps, Function Apps → **stopped**
3. ML endpoints → **disabled**
4. User receives enforcement email
5. 5-day grace period starts
6. After grace period → all resources **deleted**

### Enforcement Reliability

| Path | How | Latency |
|------|-----|---------|
| Budget notification | Webhook → Automation Runbook | 8-24h (Azure cost data delay) |
| Daily scheduled check | Runbook queries Cost Management API at 06:00 UTC | ≤ 24h |

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| [Azure CLI](https://aka.ms/installazurecli) | ≥ 2.60 | `winget install Microsoft.AzureCLI` |
| [PowerShell](https://github.com/PowerShell/PowerShell) | ≥ 7.4 | `winget install Microsoft.PowerShell` |
| [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) | ≥ 0.28 | `az bicep install` (automatic) |
| Git | ≥ 2.0 | `winget install Git.Git` |

### Azure Requirements

| Requirement | Details |
|-------------|---------|
| **Subscription Owner** | To create RGs, deploy resources, manage RBAC |
| **Billing Account access** | To create subscriptions (Step 1 only) |
| **Entra ID read access** | To resolve user Object IDs |

See [Admin Connection Guide](docs/admin-connection-guide.md) for detailed setup instructions.

---

## Input File Format

**CSV** (`input/users.csv`):
```csv
UserPrincipalName,DisplayName,Email,Department,CostCenter,SubscriptionId
john.doe@contoso.com,John Doe,john.doe@contoso.com,Engineering,CC-1001,
jane.smith@contoso.com,Jane Smith,jane.smith@contoso.com,Data Science,CC-1002,
```

**JSON** (`input/users.json`):
```json
{
  "users": [
    {
      "userPrincipalName": "john.doe@contoso.com",
      "displayName": "John Doe",
      "email": "john.doe@contoso.com",
      "department": "Engineering",
      "costCenter": "CC-1001",
      "subscriptionId": ""
    }
  ]
}
```

| Column | Required | Description |
|--------|----------|-------------|
| `UserPrincipalName` | Yes | User's login email (e.g., `john.doe@contoso.com`) |
| `DisplayName` | Yes | User's display name |
| `Email` | Yes | Email for budget notifications |
| `Department` | No | For tagging |
| `CostCenter` | No | For tagging |
| `SubscriptionId` | No | Pre-existing subscription ID. If empty, uses the admin's current subscription. |

---

## Optional: User Creation

If users don't already exist in Entra ID:

```powershell
# Preview
pwsh ./scripts/New-TenantUsers.ps1 -InputFile "./input/users.csv" -WhatIf

# Create users (generates random temp passwords)
pwsh ./scripts/New-TenantUsers.ps1 -InputFile "./input/users.csv"
```

Outputs credentials to `output/new-users-{timestamp}.csv`. Requires Global Admin or User Admin role.

---

## Cleanup

```powershell
# Remove one user
pwsh ./scripts/Remove-UserEnvironment.ps1 `
    -UserPrincipalName "john.doe@contoso.com" `
    -SubscriptionId "xxxx"

# Remove all users
Import-Csv "./input/users.csv" | ForEach-Object {
    pwsh ./scripts/Remove-UserEnvironment.ps1 `
        -UserPrincipalName $_.UserPrincipalName `
        -SubscriptionId "xxxx" -Force
}
```

---

## Customization

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Location` | `swedencentral` | Azure region |
| `-WarningBudget` | `15` | Warning threshold (USD) |
| `-HardLimitBudget` | `20` | Enforcement threshold (USD) |
| `-GracePeriodDays` | `5` | Days before deletion |

---

## CI/CD with GitHub Actions

The included workflow (`.github/workflows/provision-users.yml`) supports:

- **Auto-provision** on push to `main` when input/infra files change
- **Manual trigger** with configurable parameters
- **PR preview** with what-if validation

Setup: Create a service principal and add `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` as repository secrets. See [Admin Connection Guide](docs/admin-connection-guide.md#advanced-service-principal-for-cicd).

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| User not found in Entra ID | Create user first (`New-TenantUsers.ps1`) or check spelling |
| AuthorizationFailed | Verify admin has Owner role on the subscription |
| AI Foundry deployment fails | Use a supported region (`swedencentral`, `eastus`) |
| Budget not enforcing | Azure cost data is delayed 8-24h; daily backup check runs at 06:00 UTC |
| User deleted the budget | Impossible — Sandbox Contributor role blocks budget modification |

---

## Project Structure

```
azure-user-provisioning/
├── infra/                              # Bicep IaC templates
│   ├── main.bicep                      # Main orchestrator (subscription scope)
│   └── modules/
│       ├── rbac.bicep                  # Sandbox Contributor + Admin Owner roles
│       ├── policy.bicep                # Custom role definition + naming policy
│       ├── aiFoundry.bicep             # AI Foundry Hub + Project + dependencies
│       ├── budget.bicep                # Budgets + Action Groups (email)
│       └── costEnforcement.bicep       # Automation Account + runbooks + schedule
├── scripts/
│   ├── New-UserSubscriptions.ps1       # Step 1: Create subscriptions (billing)
│   ├── Deploy-UserEnvironment.ps1      # Step 2: Main provisioning script
│   ├── Remove-UserEnvironment.ps1      # Cleanup / teardown
│   ├── New-TenantUsers.ps1            # Optional: Create Entra ID users
│   └── runbooks/
│       ├── Invoke-CostEnforcement.ps1  # Budget enforcement runbook
│       └── Invoke-GracePeriodCleanup.ps1
├── input/                              # User input files (edit these)
│   ├── users.csv
│   └── users.json
├── docs/
│   ├── functional-requirements.md      # What this solution does and why
│   ├── admin-connection-guide.md       # How to connect (beginner-friendly)
│   └── sample-walkthrough.md           # End-to-end step-by-step guide
├── .github/workflows/
│   └── provision-users.yml             # GitHub Actions CI/CD
├── .gitignore
├── LICENSE
└── README.md
```

---

## Documentation

| Document | Audience | Description |
|----------|----------|-------------|
| [Functional Requirements](docs/functional-requirements.md) | All | What the solution does and the original requirements |
| [Admin Connection Guide](docs/admin-connection-guide.md) | Beginners | Azure concepts, tool installation, authentication |
| [Sample Walkthrough](docs/sample-walkthrough.md) | Beginners | Complete step-by-step deployment guide |

---

## License

MIT License — see [LICENSE](LICENSE) for details.

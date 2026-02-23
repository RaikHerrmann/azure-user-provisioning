# Azure User Sandbox Provisioning

Automated Infrastructure-as-Code solution for provisioning per-user Azure sandbox environments with AI Foundry, cost controls, and automated enforcement.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Execution Modes](#execution-modes)
- [Detailed Setup](#detailed-setup)
- [What Gets Deployed](#what-gets-deployed)
- [Security Model](#security-model)
- [Cost Management](#cost-management)
- [Optional: User Creation Module](#optional-user-creation-module)
- [Cleanup](#cleanup)
- [CI/CD with GitHub Actions](#cicd-with-github-actions)
- [Customization](#customization)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)
- [Documentation](#documentation)
- [Contributing](#contributing)

---

## Overview

This solution enables a tenant administrator to repeatably provision isolated Azure sandbox environments for multiple users from a simple CSV or JSON input file. Each user receives:

| Feature | Description |
|---------|-------------|
| **Resource Group** | Pre-created default RG; user **cannot** create additional RGs |
| **AI Foundry** | Azure AI Hub + Project with storage, Key Vault, and monitoring |
| **RBAC** | Contributor within their RG only; custom deny role at subscription scope |
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
│  │  │  │ Hub + Project│  │ (RBAC auth)  │  │ Account      │   ││  │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘   ││  │
│  │  │                                                          ││  │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   ││  │
│  │  │  │ App Insights │  │ Log          │  │ Automation   │   ││  │
│  │  │  │              │  │ Analytics    │  │ Account (MI) │   ││  │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘   ││  │
│  │  │                                                          ││  │
│  │  └──────────────────────────────────────────────────────────┘│  │
│  │                                                               │  │
│  │  ┌─── Subscription-Level Controls ───────────────────────────┐│  │
│  │  │  • Custom Role: Deny RG create/delete                     ││  │
│  │  │  • Azure Policy: Naming convention guardrail (rg-*)       ││  │
│  │  │  • Budget: $15 warn / $20 enforce (email + automation)    ││  │
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

### Security Boundary Model (2 Layers)

| Layer | Mechanism | Purpose |
|-------|-----------|--------|
| **Layer 1** (RBAC) | Contributor at **RG scope only** | User has no subscription-level perms — cannot create RGs |
| **Layer 2** (Policy) | Naming convention: `rg-*` only | Guardrail if future role changes widen permissions |

## Prerequisites

### Software Requirements

| Tool | Version | Purpose |
|------|---------|---------|
| [Azure CLI](https://aka.ms/installazurecli) | >= 2.60 | Azure management |
| [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) | >= 0.28 | IaC compilation (auto-installed with Azure CLI) |
| PowerShell | >= 7.4 | Orchestration scripts |
| Git | >= 2.0 | Version control |

### Azure Requirements

| Requirement | Details |
|-------------|---------|
| **Tenant Admin** | Global Administrator or Subscription Owner role |
| **Entra ID Access** | User.Read.All to resolve Object IDs from UPNs |
| **Resource Providers** | Several providers must be registered (handled automatically by script) |

See the **[Admin Connection Guide](docs/admin-connection-guide.md)** for detailed authentication options (interactive, service principal, managed identity).

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/RaikHerrmann/azure-user-provisioning.git
cd azure-user-provisioning

# 2. Login to Azure as tenant admin
az login --tenant YOUR_TENANT_ID

# 3. Edit the input file with your users
#    Edit input/users.csv or input/users.json

# 4. Preview changes first (what-if)
cd scripts
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -WhatIf

# 5. Deploy all users
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -Location "swedencentral"
```

## Execution Modes

The solution supports three execution modes to accommodate testing, debugging, and production use:

### 1. Full Batch (All Users at Once)

```powershell
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv"
```

Processes all users from the input file sequentially. Best for production deployments.

### 2. Step-by-Step (Interactive with Pauses)

```powershell
pwsh ./Deploy-UserEnvironment.ps1 -InputFile "../input/users.csv" -Step
```

Pauses after each phase for you to review:
- Phase 1: Prerequisites validation
- Phase 2: Input file reading
- Phase 3: Entra ID identity resolution
- Phase 4: Resource provider registration
- Phase 5: Per-user Bicep deployment + runbook upload
- Phase 6: Summary

Press ENTER to continue or `q` to quit at any pause.

### 3. Single User (Testing / Debugging)

```powershell
pwsh ./Deploy-UserEnvironment.ps1 `
  -InputFile "../input/users.csv" `
  -SingleUser "john.doe@contoso.com" `
  -Step
```

Deploys for one user only. Combine with `-Step` for full debugging control.

## Detailed Setup

See the **[Sample Walkthrough](docs/sample-walkthrough.md)** for a complete end-to-end guide with example commands and expected outputs.

### Input File Format

**CSV** (`input/users.csv`):
```csv
UserPrincipalName,DisplayName,Email,Department,CostCenter
john.doe@contoso.com,John Doe,john.doe@contoso.com,Engineering,CC-1001
jane.smith@contoso.com,Jane Smith,jane.smith@contoso.com,Data Science,CC-1002
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
      "costCenter": "CC-1001"
    }
  ]
}
```

Optional columns: `SubscriptionId` (to use an existing subscription instead of the current one).

## What Gets Deployed

### Per-User Resources

| Resource | Name Pattern | Purpose |
|----------|-------------|---------|
| **Resource Group** | `rg-{user-sanitized}` | Isolated container |
| **Azure AI Hub** | `aihub-{unique}` | AI Foundry workspace |
| **Azure AI Project** | `aiproj-{unique}` | AI project within hub |
| **Storage Account** | `staifoundry{unique}` | Data storage (shared key disabled) |
| **Key Vault** | `kv-ai-{unique}` | Secrets (RBAC auth, no access policies) |
| **Application Insights** | `appi-ai-{unique}` | Monitoring |
| **Log Analytics** | `log-ai-{unique}` | Logging |
| **Automation Account** | `aa-cost-{unique}` | Cost enforcement (System MI) |
| **Budget** | `budget-{unique}` | Monthly budget with thresholds |
| **Action Groups** | `ag-warning-*`, `ag-enforce-*` | Email notifications |

### RBAC Assignments

| Principal | Role | Scope |
|-----------|------|-------|
| User | **Contributor** | Resource Group |
| User | **Azure AI Developer** | AI Foundry Hub |
| User | **Cognitive Services OpenAI User** | AI Foundry Hub |
| Tenant Admin | **Owner** | Resource Group |
| Automation MI | **Contributor** | Resource Group |
| Automation MI | **User Access Administrator** | Resource Group |

## Security Model

### What Users CAN Do

- Create, manage, delete resources **within** their resource group
- Use AI Foundry (Hub + Project)
- Access Key Vault via RBAC

### What Users CANNOT Do

- Create or delete resource groups
- Access other users' resource groups
- Modify RBAC assignments
- Modify subscription-level settings
- Access resources outside their sandbox

## Cost Management

| Threshold | Trigger | Actions |
|-----------|---------|---------|
| **$15** (75%) | Actual cost >= $15 | Warning email |
| **90% Forecast** | Forecasted >= 90% | Proactive warning email |
| **$20** (100%) | Actual cost >= $20 | Full enforcement |

### Enforcement at $20

1. User's Contributor role → Reader (read-only)
2. All VMs, Web Apps, Function Apps stopped
3. ML endpoints disabled
4. User notified via email
5. 5-day grace period scheduled

### Enforcement Reliability

| Path | How | Latency |
|------|-----|---------|
| Budget notification | Email via Action Group | 8-24h (Azure cost data delay) |
| Daily scheduled check | Runbook queries Cost Management API | <= 24h (runs at 06:00 UTC) |

## Optional: User Creation Module

If users don't already exist in Entra ID:

```powershell
# Preview
pwsh ./scripts/New-TenantUsers.ps1 -InputFile "./input/users.csv" -WhatIf

# Create users (generates random temp passwords)
pwsh ./scripts/New-TenantUsers.ps1 -InputFile "./input/users.csv"
```

Outputs credentials to `output/new-users-{timestamp}.csv`. Requires Global Admin or User Admin role.

## Cleanup

```powershell
# Remove single user
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

Cleans up: resources, resource group, custom roles, policies, RBAC, deployment history.

## CI/CD with GitHub Actions

The included workflow (`.github/workflows/provision-users.yml`) supports:

- **Auto-provision** on push to `main` when input/infra files change
- **Manual trigger** with configurable parameters
- **PR preview** with what-if validation
- **Log upload** as build artifact

Setup: Create a service principal, add `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` as repo secrets. See [Admin Connection Guide](docs/admin-connection-guide.md#option-2-service-principal-recommended-for-cicd).

## Customization

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Location` | `swedencentral` | Azure region |
| `WarningBudget` | `15` | Warning threshold (USD) |
| `HardLimitBudget` | `20` | Enforcement threshold (USD) |
| `GracePeriodDays` | `5` | Days before deletion |

To add resources: create Bicep modules in `infra/modules/` and wire in `infra/main.bicep`.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| User not found in Entra ID | Create user first or use `New-TenantUsers.ps1` |
| AuthorizationFailed | Verify admin has Owner + UAA roles |
| AI Foundry deployment fails | Use a supported region |
| Budget not enforcing | Daily schedule backup checks every 24h |

## Project Structure

```
azure-user-provisioning/
├── infra/                              # Bicep IaC templates
│   ├── main.bicep                      # Main orchestrator (subscription scope)
│   └── modules/
│       ├── rbac.bicep                  # RBAC role assignments
│       ├── policy.bicep                # Custom deny role + naming policy
│       ├── aiFoundry.bicep             # AI Foundry Hub + Project + deps
│       ├── budget.bicep                # Budgets + Action Groups (email)
│       └── costEnforcement.bicep       # Automation + runbooks + schedule
├── scripts/                            # PowerShell orchestration
│   ├── Deploy-UserEnvironment.ps1      # Main provisioning (batch/step/single)
│   ├── Remove-UserEnvironment.ps1      # Cleanup/teardown
│   ├── New-TenantUsers.ps1            # Optional: Entra ID user creation
│   └── runbooks/
│       ├── Invoke-CostEnforcement.ps1  # Budget enforcement runbook
│       └── Invoke-GracePeriodCleanup.ps1
├── input/                              # User input files
│   ├── users.csv                       # CSV example
│   └── users.json                      # JSON example
├── docs/                               # Documentation
│   ├── admin-connection-guide.md       # How to connect as admin
│   └── sample-walkthrough.md           # End-to-end walkthrough
├── .github/workflows/
│   └── provision-users.yml             # GitHub Actions CI/CD
├── .gitignore
├── LICENSE
└── README.md
```

## Documentation

| Document | Description |
|----------|-------------|
| **[Admin Connection Guide](docs/admin-connection-guide.md)** | Authentication options (interactive, service principal, MI) |
| **[Sample Walkthrough](docs/sample-walkthrough.md)** | Complete end-to-end deployment example |

## Contributing

1. Fork this repository
2. Create a feature branch: `git checkout -b feature/my-change`
3. Commit changes: `git commit -am 'Add feature'`
4. Push: `git push origin feature/my-change`
5. Create a Pull Request

## License

MIT License — see [LICENSE](LICENSE) for details.

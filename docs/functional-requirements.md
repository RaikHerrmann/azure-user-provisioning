# Functional Requirements

This document describes what this solution does, why it was built, and the requirements it fulfils.

---

## Problem Statement

A **tenant administrator** needs to provision isolated Azure sandbox environments for multiple users (e.g., AI researchers, students, new team members). Each user should be able to experiment freely within their own environment, but:

- They must **not** be able to access other users' environments
- They must **not** be able to create resources outside their assigned boundaries
- They must **not** be able to disable their own cost controls
- Their spending must be monitored and **automatically enforced**
- The entire setup must be **repeatable and automated** (Infrastructure as Code)
- All subscriptions must be under the **same billing account** for centralized cost visibility

---

## Functional Requirements

### FR-1: Per-User Isolated Environments

- Each user gets their own Azure subscription (created under the same billing account)
- Each user gets exactly **one** pre-created resource group
- Users **cannot** create additional resource groups
- Users **cannot** access other users' resource groups or subscriptions

### FR-2: Azure AI Foundry

- Each user's environment includes an Azure AI Foundry Hub and Project
- Supporting resources (Storage Account, Key Vault, Application Insights, Log Analytics) are pre-deployed
- Users have the AI Developer and Cognitive Services OpenAI User roles on their AI Hub

### FR-3: Cost Monitoring — Warning at $15

- An Azure Budget monitors each user's monthly spending
- When spending reaches **$15** (75% of the $20 limit), the user receives a **warning email**
- A forecasted spending warning is sent at **90%** projected spend
- No automated actions are taken at the warning level — it is informational only

### FR-4: Cost Enforcement — Hard Limit at $20

- When actual spending reaches **$20**, automated enforcement kicks in:
  1. The user's role is changed from Sandbox Contributor to **Reader** (read-only)
  2. All running compute resources (VMs, Web Apps, Function Apps) are **stopped**
  3. All AI/ML inference endpoints are **disabled**
  4. The user receives an **enforcement notification email**
  5. A **5-day grace period** begins, during which the user can view but not modify resources

### FR-5: Grace Period Cleanup (5 Days After Enforcement)

- After the grace period expires, a cleanup runbook automatically runs
- All resources within the user's resource group are **deleted** (in dependency order)
- User RBAC assignments are removed
- The admin is left with a clean environment for potential re-provisioning

### FR-6: Tamper-Proof Cost Controls

- Users **cannot** delete or modify the Automation Account that enforces cost limits
- Users **cannot** delete or modify the Budget that triggers enforcement
- Users **cannot** delete or modify the Action Groups that send notifications
- This is enforced through a custom RBAC role ("Sandbox Contributor") with `notActions`

### FR-7: Billing Account Consolidation

- All subscriptions created for users are under the **same billing account**
- This ensures centralized cost visibility and billing management
- The admin specifies the billing scope during subscription creation (Step 1)

**Billing Type Support:**

| Billing Type | Automated Creation (Step 1) | Centralized Billing |
|---|---|---|
| **MCA** (Microsoft Customer Agreement) | Yes — fully automated | Yes |
| **EA** (Enterprise Agreement) | Yes — fully automated | Yes |
| **Modern PAYG** (post-2019 credit card) | Yes — uses MCA format | Yes |
| **CSP** (Cloud Solution Provider) | No — partner creates via Partner Center | Yes (managed by CSP partner) |
| **Legacy MOSP** (pre-2019 PAYG) | No — create manually or upgrade to MCA | Yes (if created under same account) |

For unsupported billing types, the script detects this automatically and guides the admin to create subscriptions manually. All subscriptions are still under a single billing arrangement regardless of creation method.

### FR-8: Repeatable Infrastructure as Code (IaC)

- The entire solution is implemented in **Azure Bicep** (declarative IaC)
- Deployments are **idempotent** — re-running the same deployment is safe
- All configuration is version-controlled in a Git repository
- CI/CD is supported via GitHub Actions

### FR-9: User Input from CSV or JSON

- The admin provides a list of users in CSV or JSON format
- Required fields: `UserPrincipalName`, `DisplayName`, `Email`
- Optional fields: `Department`, `CostCenter`, `SubscriptionId`

### FR-10: Admin Flexibility

- The admin can deploy **all users at once** (batch mode)
- The admin can deploy a **single user** for testing
- The admin can **step through** the deployment phase by phase
- The admin can **preview changes** with what-if before applying
- The admin can **tear down** individual user environments

---

## Non-Functional Requirements

### Security — 3-Layer Protection Model

| # | Layer | Mechanism | What It Prevents |
|---|-------|-----------|-----------------|
| 1 | **Custom RBAC Role** | Sandbox Contributor (Contributor minus cost infra) | Cannot modify/delete Automation Account, Budgets, Action Groups |
| 2 | **RBAC Scope** | Role assigned at Resource Group scope only | Cannot create/delete RGs, cannot access other users' RGs |
| 3 | **Azure Policy** | Naming convention guardrail (`rg-*`) | Additional safety net against accidental permission expansion |

### Cost Thresholds (Defaults — All Configurable)

| Config | Default | Flag |
|--------|---------|------|
| Warning threshold | $15 USD | `-WarningBudget` |
| Hard limit | $20 USD | `-HardLimitBudget` |
| Grace period | 5 days | `-GracePeriodDays` |
| Monthly reset | 1st of each month | Automatic |

### Enforcement Latency

- Azure cost data can be delayed **8–24 hours**
- **Primary path**: Budget notification → Action Group → Webhook → Automation Runbook
- **Backup path**: Daily scheduled runbook at 06:00 UTC queries Cost Management API directly
- **Worst case**: Enforcement within 24 hours of exceeding the hard limit

---

## Architecture Decisions

### Why a Custom RBAC Role (Not Just Built-in Contributor)?

Built-in Contributor lets users delete **any** resource in their RG, including the Automation Account, Budget, and Action Groups. If a user deletes these, cost enforcement stops working entirely. The custom "Sandbox Contributor" role uses `notActions` to block modification of these specific resources while allowing everything else.

### Why Not Azure Policy for Delete Protection?

Azure Policy `deny` effect is evaluated during resource **creation and update** operations, **not** during delete operations. Azure Policy cannot prevent a user from deleting a resource.

### Why Not Resource Locks?

Users with Contributor permissions can delete resource locks (`Microsoft.Authorization/locks/*`). Only removing this permission via `notActions` in the custom role provides reliable protection.

### Why Per-Subscription Isolation?

Per-subscription isolation provides the strongest boundary:
- Subscription-level quotas and limits are separate
- Billing is naturally separated
- No risk of cross-user resource access even if RBAC is misconfigured

For **testing**, multiple users can share a single subscription with per-RG isolation. This works because the custom role + RG scoping still prevents cross-user access.

### Why Two Enforcement Paths (Webhook + Schedule)?

1. **Budget → Webhook → Runbook**: Near-real-time enforcement (subject to Azure cost data delay)
2. **Daily scheduled runbook**: Backup in case budget notifications fail, are delayed, or the webhook expires

Both paths run the **same** enforcement logic, ensuring consistency.

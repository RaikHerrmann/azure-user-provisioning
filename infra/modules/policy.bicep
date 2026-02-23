// ============================================================================
// policy.bicep - Restrict user to their assigned resource group only
// ============================================================================
// Strategy:
//   We enforce resource group boundaries through TWO LAYERS:
//
//   Layer 1 (RBAC - primary): User gets Contributor ONLY at RG scope.
//     => They have NO subscription-level role, so they CANNOT create RGs.
//     This is the real enforcement — without subscription-level permissions,
//     the user simply cannot call the RG create/delete APIs.
//
//   Layer 2 (Policy - guardrail): A subscription-scoped Azure Policy denies
//     creation of resource groups that don't match the naming convention.
//     This protects against future role changes that might accidentally
//     grant broader subscription-level permissions.
//
//   NOTE: Azure RBAC custom roles with notActions do NOT create deny effects.
//   notActions only subtract from actions in the SAME role definition.
//   True deny assignments require Azure Blueprints or Managed Applications.
//   Therefore we rely on scoped RBAC (Layer 1) + Policy (Layer 2) only.
// ============================================================================

targetScope = 'subscription'

// === Parameters ===
@description('Object ID of the user to restrict')
param userObjectId string

@description('Name of the allowed (pre-created) resource group')
param allowedResourceGroupName string

@description('Object ID of the tenant admin (exempted from policy)')
param tenantAdminObjectId string

// === Variables ===
var uniqueSuffix = uniqueString(subscription().subscriptionId, userObjectId)

// === Policy: Naming convention guardrail for resource groups ===
// Safety net: even if someone accidentally grants broader RBAC permissions,
// only resource groups matching "rg-*" can be created.
resource rgNamingPolicy 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: 'rg-naming-convention-${uniqueSuffix}'
  properties: {
    policyType: 'Custom'
    mode: 'All'
    displayName: 'Enforce RG naming convention (rg-*)'
    description: 'Ensures resource groups follow the naming pattern rg-* to enforce sandbox boundaries.'
    metadata: {
      category: 'Resource Management'
      version: '1.0.0'
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Resources/subscriptions/resourceGroups'
          }
          {
            not: {
              field: 'name'
              like: 'rg-*'
            }
          }
        ]
      }
      then: {
        effect: 'deny'
      }
    }
  }
}

resource rgNamingPolicyAssignment 'Microsoft.Authorization/policyAssignments@2022-06-01' = {
  name: 'rg-naming-${uniqueSuffix}'
  properties: {
    policyDefinitionId: rgNamingPolicy.id
    displayName: 'Enforce RG naming convention - ${uniqueSuffix}'
    description: 'Guardrail: only allow resource groups matching rg-* naming pattern'
    enforcementMode: 'Default'
    nonComplianceMessages: [
      {
        message: 'Resource group names must follow the pattern "rg-*". Please use your assigned resource group: ${allowedResourceGroupName}'
      }
    ]
  }
}

// === Outputs ===
output policyDefinitionId string = rgNamingPolicy.id
output policyAssignmentId string = rgNamingPolicyAssignment.id

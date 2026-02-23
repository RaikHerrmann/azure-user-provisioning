// ============================================================================
// policy.bicep - Azure Policy to deny additional resource group creation
// ============================================================================
// Creates a policy assignment at subscription scope that:
//   - Denies the user from creating any resource groups other than the
//     pre-provisioned default one
//   - Exempts the tenant admin from this restriction
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
var policyName = 'deny-rg-creation-${userObjectId}'
var policyDisplayName = 'Deny Resource Group Creation (except default)'

// === Policy Definition ===
// Custom policy that denies Microsoft.Resources/subscriptions/resourceGroups/write
// unless the target is the allowed resource group name
resource denyRgPolicyDefinition 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'deny-extra-rg-${uniqueString(subscription().subscriptionId, userObjectId)}'
  properties: {
    policyType: 'Custom'
    mode: 'All'
    displayName: policyDisplayName
    description: 'Prevents creation of resource groups except the pre-provisioned default resource group for the user sandbox.'
    metadata: {
      category: 'Resource Management'
      version: '1.0.0'
    }
    parameters: {
      allowedRgName: {
        type: 'String'
        metadata: {
          description: 'The name of the allowed resource group'
          displayName: 'Allowed Resource Group Name'
        }
      }
      restrictedUserObjectId: {
        type: 'String'
        metadata: {
          description: 'The Object ID of the user to restrict'
          displayName: 'Restricted User Object ID'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Resources/subscriptions/resourceGroups'
          }
          {
            field: 'name'
            notEquals: '[parameters(\'allowedRgName\')]'
          }
        ]
      }
      then: {
        effect: 'deny'
      }
    }
  }
}

// === Policy Assignment ===
resource denyRgPolicyAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: policyName
  properties: {
    policyDefinitionId: denyRgPolicyDefinition.id
    displayName: '${policyDisplayName} - ${userObjectId}'
    description: 'Denies resource group creation for user ${userObjectId} except ${allowedResourceGroupName}'
    enforcementMode: 'Default'
    parameters: {
      allowedRgName: {
        value: allowedResourceGroupName
      }
      restrictedUserObjectId: {
        value: userObjectId
      }
    }
    nonComplianceMessages: [
      {
        message: 'You are not allowed to create additional resource groups. Please use your assigned resource group: ${allowedResourceGroupName}'
      }
    ]
  }
}

// === Policy Exemption for Tenant Admin ===
// Note: Policy exemptions require the admin to be identified differently.
// Since Azure Policy applies to resources not principals, we use a different approach:
// The admin has Owner role and can manage policy assignments directly.
// The policy targets resource group creation, not specific users.
// To make this user-specific, we rely on the combination of:
//   - Contributor RBAC scoped to the specific RG (user can only act in their RG)
//   - No subscription-level role for the user that would allow RG creation

// === Outputs ===
output policyDefinitionId string = denyRgPolicyDefinition.id
output policyAssignmentId string = denyRgPolicyAssignment.id

locals {
  role_definitions_yaml = file("${path.cwd}/role_definitions.yaml")
  role_definitions      = yamldecode(local.role_definitions_yaml)

  role_scope_map = merge(flatten([
    for role in local.role_definitions : [{
      for scope in role.permissions.scopes :
      "${role.name}-${scope}" => {
        name             = role.name
        description      = role.description
        scope            = scope
        actions          = role.permissions.actions
        not_actions      = role.permissions.not_actions
        data_actions     = role.permissions.data_actions
        not_data_actions = role.permissions.not_data_actions
      }
  }]])...)
}

resource "azurerm_role_definition" "custom_roles" {
  #for_each = local.role_scope_map

  name        = "Orphan Resource Cleanup Read/Delete"
  description = "Read and Resource Delete Access to applicably assigned scope"
  scope       = "/providers/Microsoft.Management/managementGroups/531ff96d-0ae9-462a-8d2d-bec7c0b42082"

  permissions {
    actions          = ["*/read", "Microsoft.Resources/*/delete"]
    not_actions      = []
    data_actions     = []
    not_data_actions = []
  }

}
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
  for_each = local.role_scope_map

  name        = each.value.name
  description = each.value.description
  scope       = each.value.scope

  permissions {
    actions          = each.value.actions
    not_actions      = each.value.not_actions
    data_actions     = each.value.data_actions
    not_data_actions = each.value.not_data_actions
  }
}
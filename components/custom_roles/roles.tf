locals {
  role_definitions_yaml = file("${path.cwd}/role_definitions.yaml")
  roles     = yamldecode(local.role_definitions_yaml).roles
}

resource "azurerm_role_definition" "custom_roles" {
  for_each = local.roles[count.index].permissions.scopes

  name        = local.roles[count.index].name
  description = local.roles[count.index].description
  scope       = each.key

  permissions {
    actions          = local.roles[count.index].permissions.actions
    not_actions      = local.roles[count.index].permissions.not_actions
    data_actions     = local.roles[count.index].permissions.data_actions
    not_data_actions = local.roles[count.index].permissions.not_data_actions
  }
}
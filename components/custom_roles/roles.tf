data "azurerm_management_group" "management_group_id" {
  name = "CFT - Sandbox"
}

output "management_group_id_output" {
  value = data.azurerm_management_group.management_group_id.id
}

resource "azurerm_role_definition" "orphan_cleanup" {
  for_each = toset(var.management_groups)

  name        = "Orphan Resource Cleanup Read/Delete"
  description = "Read and Resource Delete Access to applicably assigned scope"
  scope       = join("/providers/Microsoft.Management/managementGroups/", [each.key])

  permissions {
    actions     = ["*/read", "Microsoft.Resources/*/delete"]
    not_actions = []
  }
}
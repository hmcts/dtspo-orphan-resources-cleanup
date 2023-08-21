resource "azurerm_role_definition" "orphan_cleanup" {
  for_each = var.management_groups

  name        = "Orphan Resource Cleanup Read/Delete"
  description = "Read and Resource Delete Access to applicably assigned scope"
  scope       = "/providers/Microsoft.Management/managementGroups/"[each.value]

  permissions {
    actions     = ["*/read", "Microsoft.Resources/*/delete"]
    not_actions = []
  }
}
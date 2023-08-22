data "azurerm_client_config" "current" {}

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
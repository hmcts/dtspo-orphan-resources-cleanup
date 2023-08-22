# data "azurerm_management_group" "management_group_id" {
#   name = "CFT-Sandbox"
# }

# output "management_group_id_output" {
#   value = data.azurerm_management_group.management_group_id.id
# }

resource "azurerm_role_definition" "orphan_cleanup" {
  for_each = toset(var.management_groups)

  name        = "Orphan Resource Cleanup Read/Delete"                          # this should be assignable
  description = "Read and Resource Delete Access to applicably assigned scope" # this should be assignable
  scope       = each.key

  permissions {
    actions     = ["*/read", "Microsoft.Resources/*/delete"]
    not_actions = []
  }

  assignable_scopes = [each.key]
}
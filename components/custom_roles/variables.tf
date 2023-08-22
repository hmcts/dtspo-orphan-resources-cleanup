variable "role_definitions" {
  description = "Settings required to create Custom Role Defintions described in README.md"
  type = list(object({
    // name of the custom Role
    name = string
    // description of the custom Role
    description = string
    // list of azure builtin role definitions to be assigned to each of defined scopes.
    permissions = list(object({
      scopes           = list(string)
      actions          = list(string)
      not_actions      = list(string)
      data_actions     = list(string)
      not_data_actions = list(string)
    }))
  }))
}

variable "subscription_id" {
  description = "Subscription to run against"
  type        = string
  default     = "04d27a32-7a07-48b3-95b8-3c8691e1a263"
}

variable "env" {
  default = []
}

variable "project" {
  default = "hmcts"
}

variable "product" {
}

variable "builtFrom" {
}

variable "location" {
  default = "UK South"
}

variable "common_tags" {
  default = []
}

variable "expiresAfter" {
  description = "Date when Sandbox resources can be deleted. Format: YYYY-MM-DD"
  default     = "3000-01-01"
}

variable "management_groups" {
  type    = list(string)
  default = []
}
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
  type = list(string)
  default = []
}
variable "env" {
  default = []
}

variable "subscription_id" {
  description = "Subscription to run against"
  type        = string
  default     = "04d27a32-7a07-48b3-95b8-3c8691e1a263"
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
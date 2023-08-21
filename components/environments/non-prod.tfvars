variable "management_groups" {
  type    = list(string)
  default = ["CFT-NonProd", "CFT-NonProd", "Heritage-NonProd", "Heritage-Sandbox", "Platform-NonProd", "Platform-Sandbox", "SDS-NonProd", "SDS-Sandbox", "Security"]
}
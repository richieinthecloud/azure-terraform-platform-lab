variable "project" {
  description = "Short project slug used in resource names (lowercase, no spaces)."
  type = string
  default = "hubnspoke"
}

variable "location" {
  description = "Azure region for the state storage account."
  type = string
  default = "eastus"
}

variable "tags" {
  description = "Tags applied to all bootstrap resources."
  type = map(string)
  default = {
    "project" = "azure-terraform-platform-lab"
    "managed_by" = "Terraform"
    "purpose" = "remote-state"
  }
}

# copy these values into environments/<env>/backend.tf after 
# 'terraform apply' 

output "resource_group_name" {
  description = "Resource group holding the Terraform state storage account."
  value = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  description = "Storage account name for the azurerm remote state backend."
  value = azurerm_storage_account.tfstate.name
}

output "container_name" {
  description = "Blob container name for the azurerm remote state backend."
  value = azurerm_storage_container.tfstate.name
}

output "backend_config_hint" {
  description = "Ready-to-paste backend block."
  value = <<-EOT
    terraform {
        backend "azurerm" {
            resource_group_name = "${azurerm_resource_group.tfstate.name}"
            storage_account_name = "${azurerm_storage_account.tfstate.name}"
            container_name = "${azurerm_storage_container.tfstate.name}"
            key = "dev.terraform.tfstate"
        }
    }
EOT
}
# Remote backend needs to be established first,
# as it will not be managed by Terraform

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerum = {
        source = "hashicorp/azurerm"
        version = "~> 3.6"
    }
    random = {
        source = "hashicorp/random"
        version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

# a short, random suffix to keep resource names globally unique
resource "random_string" "suffix" {
    length = 6
    upper = false
    special = false
}

resource "azurerm_resource_group" "tfstate" {
    name = "rg-tfstate-${var.project}"
    location = var.location
    tags = var.tags
}

resource "azurerm_storage_account" "tfstate" {
    name = "st${var.project}tfstate${random_string.suffix.result}"
    resource_group_name = azurerm_resource_group.tfstate.name
    location = azurerm_resource_group.tfstate.location
    account_tier = "Standard"
    account_replication_type = "LRS"

# security hardening for a state store. These files hold very sensitive data
    min_tls_version = "TLS1_2"
    allow_nested_items_to_be_public = false
    shared_access_key_enabled = true # this is required for the azureerm backend

    blob_properties {
      versioning_enabled = true
    }
# this keeps state history. Allows us to recover in the event of failure

    tags = var.tags
}

resource "azurerm_storage_container" "tfstate" {
  name = "tfstate"
  storage_account_id = azurerm_resource_group.tfstate.id
  container_access_type = "private"
}

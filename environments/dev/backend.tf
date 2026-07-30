terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-hubspoke"
    storage_account_name = "[replace_with_bootstrap_output]"
    container_name       = "tfstate"
    key                  = "dev.terraform.tfstate" #this would be the name of our remote state file
    use_azuread_auth     = true
    # i could alternatively use federated credentials (OIDC)
  }
}
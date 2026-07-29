terraform {
    backend "azurerm" {
        resource_group_name = "filler-text"
        storage_account_name = "filler-text"
        container_name = "filler-text"
        key = "[env].terraform.tfstate" #this would be the name of our remote state file
        use_azuread_auth = true
        # i could alternatively use federated credentials (OIDC)
    }
}
resource "azurerm_resource_group" "DemoRG" {
  name     = "rg-github-actions-test"
  location = "East US"
}

# workflow trigger test

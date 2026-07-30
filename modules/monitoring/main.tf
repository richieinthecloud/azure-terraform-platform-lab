# Monitoring module 

# Create an Azure Log Analytics workspace that Firewall, Bastion and anything else send their 
# diagnostic logs and metrics to. Diagnostic settings that point resources at this workspace live
# in the environment root, so this module stays simple. 

resource "azurerm_resource_group" "monitoring" {
  name = "rg-monitoring-${var.env}"
  location = var.location
  tags = var.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name = "log-hubspoke-${var.env}"
  location = azurerm_resource_group.monitoring.location
  resource_group_name = azurerm_resource_group.monitoring.name
  sku = "PerGB2018" # standard pay-per-GB tier
  retention_in_days = var.retention_in_days # 30 days is the free minimum
  tags = var.tags
}

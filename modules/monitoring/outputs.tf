output "resource_group_name" {
  description = "Monitoring resource group name."
  value       = azurerm_resource_group.monitoring.name
}

output "workspace_id" {
  description = "Log Analytics workspace resource ID (target for diagnostic settings)."
  value       = azurerm_log_analytics_workspace.this.id
}

output "workspace_name" {
  description = "Log Analytics workspace name."
  value       = azurerm_log_analytics_workspace.this.name
}
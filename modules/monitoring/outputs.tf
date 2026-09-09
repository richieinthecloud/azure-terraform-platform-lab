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

output "action_group_id" {
  description = "Platform action group resource ID (attach additional alerts to it)."
  value       = azurerm_monitor_action_group.platform.id
}

output "data_collection_rule_id" {
  description = "Linux Data Collection Rule ID for the Azure Monitor Agent. null unless enable_vm_monitoring is true."
  value       = one(azurerm_monitor_data_collection_rule.linux[*].id)
}

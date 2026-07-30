output "firewall_private_ip" {
  description = "Hub Azure Firewall private IP (spoke UDR next hop)."
  value       = module.hub.firewall_private_ip
}

output "vpn_gateway_public_ip" {
  description = "Hub VPN gateway public IP (StrongSwan peers to this)."
  value       = module.hub.vpn_gateway_public_ip
}

output "onprem_vpn_device_public_ip" {
  description = "On-prem StrongSwan public IP (Local Network Gateway address)."
  value       = module.onprem.vpn_device_public_ip
}

output "onprem_server_private_ip" {
  description = "On-prem server VM private IP (ping/ssh target for the hybrid demo)."
  value       = module.onprem.lan_vm_private_ip
}

output "app_vm_private_ip" {
  description = "Spoke-app VM private IP."
  value       = azurerm_network_interface.app.private_ip_address
}

output "data_vm_private_ip" {
  description = "Spoke-data VM private IP."
  value       = azurerm_network_interface.data.private_ip_address
}

output "data_storage_account_name" {
  description = "Private-endpoint-only storage account name."
  value       = azurerm_storage_account.data.name
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace collecting Firewall/Bastion diagnostics."
  value       = module.monitoring.workspace_name
}
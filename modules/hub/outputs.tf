output "resource_group_name" {
  description = "Hub resource group name."
  value       = azurerm_resource_group.hub.name
}

output "vnet_id" {
  description = "Hub Vnet resource ID."
  value       = azurerm_virtual_network.hub.id
}

output "vnet_name" {
  description = "Hub VNet name (needed for reverse peering)."
  value       = azurerm_virtual_network.hub.name
}

output "firewall_private_ip" {
  description = "Azure Firewall private IP - the next hop for spoke UDRs."
  value       = azurerm_firewall.hub.ip_configuration[0].private_ip_address
}

output "firewall_id" {
  description = "Azure Firewall resource ID (target for diagnostic settings)."
  value       = azurerm_firewall.hub.id
}

output "bastion_id" {
  description = "Azure Bastion resource ID (target for diagnostic settings)."
  value       = azurerm_bastion_host.hub.id
}

output "vpn_gateway_id" {
  description = "VPN Gateway resource ID (used by the S2S connection)."
  value       = azurerm_virtual_network_gateway.hub.id
}

output "vpn_gateway_public_ip" {
  description = "VPN Gateway public IP - StrongSwan connections to this."
  value       = azurerm_public_ip.vpn_gw.ip_address
}

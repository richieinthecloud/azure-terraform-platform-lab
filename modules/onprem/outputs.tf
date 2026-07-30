output "resource_group_name" {
  description = "On-prem resource group name."
  value = azurerm_resource_group.onprem.name
}

output "vpn_device_public_ip" {
  description = "StrongSwan public IP - used as the Local Network Gateway address in Azure."
  value = azurerm_public_ip.strongswan.ip_address
}

output "address_space" {
  description = "On-prem address space (for the Local Network Gateway)."
  value = var.address_space
}

output "lan_vm_private_ip" {
  description = "On-prem server VM private IP (target for reachability tests)."
  value = azurerm_network_interface.lan_vm.private_ip_address
}
output "resource_group_name" {
  description = "Spoke resource group name."
  value = azurerm_resource_group.spoke1.name
}

output "vnet_id" {
  description = "Spoke1 Vnet ID."
  value = azurerm_virtual_network.spoke1.id
}

output "vnet_name" {
  description = "Spoke1 Vnet name."
  value = azurerm_virtual_network.spoke1.name
}

output "subnet_ids" {
  description = "Map of subnet names => subnet ID."
  value = { for k, s in azurerm_subnet.this : k => s.id }
}

output "workload_subnet_id" {
  description = "ID of the worload subnet."
  value = azurerm_subnet.this[var.workload_subnet_name].id
}
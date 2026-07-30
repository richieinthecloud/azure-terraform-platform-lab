# Spoke module - Workload VNet peered to the hub

# In here we make a spoke Vnet, an NSG, a route table that forces egress through the firewall, 
# and the two-way Vnet peering with gateway transit so the spoke can reach on-prem via the hub VPN gateway

resource "azurerm_resource_group" "spoke" {
  name     = "rg-spoke-${var.name}-${var.env}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-spoke-${var.name}-${var.env}"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  address_space       = [var.address_space]
  tags                = var.tags
}

# subnets are driven by a map so adding one is a variable entry, not new HCL
resource "azurerm_subnet" "this" {
  for_each = var.subnets

  name                 = each.key
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [each.value]

  # private endpoints need network policies configurable; harmless elsewhere
  private_endpoint_network_policies = "Enabled"
}

# NSG - attached to the workload subnet. Baseline deny; Bastion + intra-vnet allowed. 
# tighten per-workload as needed

resource "azurerm_network_security_group" "workload" {
  name                = "nsg-spoke-${var.name}-${var.env}"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.tags

  security_rule {
    name                       = "Allow-Bastion-SSH-RDP"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = var.bastion_subnet_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Vnet-Inbound"
    priority                   = 1005
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  subnet_id                 = azurerm_subnet.this[var.workload_subnet_name].id
  network_security_group_id = azurerm_network_security_group.workload.id
}

# route table - default route to the hub firewall. This is what makes the firewall
# an inline inspection point instead of a bypassed appliance

resource "azurerm_route_table" "spoke" {
  name                = "rt-spoke-${var.name}-${var.env}"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.tags

  route {
    name                   = "default-to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "workload" {
  subnet_id      = azurerm_subnet.this[var.workload_subnet_name].id
  route_table_id = azurerm_route_table.spoke.id
}

# VNet peering (both directions) Gateway transit lets this spoke reach on-prem resources through the
# hub's VPN gateway without a gateway of its own 

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "peer-${var.name}-to-hub"
  resource_group_name          = azurerm_resource_group.spoke.name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = var.hub_vnet_id
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = var.use_remote_gateways
  allow_virtual_network_access = true

  depends_on = [azurerm_virtual_network_peering.hub_to_spoke]
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "peer-hub-to-${var.name}"
  resource_group_name          = var.hub_resource_group_name
  virtual_network_name         = var.hub_vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.spoke.id
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  use_remote_gateways          = false
  allow_virtual_network_access = true
}
# My hub modfule - the shared-services VNet.

# This contains the hub vnet, mandatory subnets (Azure Firewall, Bastion and VPN Gateway)
# This is where our Site-to-Site tunnel terminates between on-prem and cloud resources

resource "azurerm_resource_group" "hub" {
  name = "rg-hub-${var.env}"
  location = var.location
  tags = var.tags
}

resource "azurerm_virtual_network" "hub" {
  name = "vnet-hub-${var.env}"
  location = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space = [var.address_space]
  tags = var.tags
}

# subnets

resource "azurerm_subnet" "firewall" {
  name = "AzureFirewallSubnet" # reserved name
  resource_group_name = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes = [var.firewall_subnet_cidr]
}

# Azure Firewall basic tier requires a management subnet + management IP
resource "azurerm_subnet" "firewall_mgmt" {
  name = "AzureFirewallManagementSubnet" # reserved name
  resource_group_name = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes = [var.firewall_mgmt_subnet_cidr]
}

resource "azurerm_subnet" "bastion" {
  name = "AzureBastionSubnet" # Reserved name
  resource_group_name = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes = [var.bastion_subnet_cidr]
}

resource "azurerm_subnet" "gateway" {
  name = "GatewaySubnet" # reserved name
  resource_group_name = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes = [var.gateway_subnet_cidr]
}

# Azure Firewall (Basic tier)

resource "azurerm_public_ip" "fw_data" {
  name = "pip-fw-data-${var.env}"
  location = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method = "Static"
  sku = "Standard"
  tags = var.tags
}

# Basic tier requires a dedicated management public IP.
resource "azurerm_public_ip" "fw_mgmt" {
  name = "pip-fw-mgmt-${var.env}"
  location = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method = "Static"
  sku = "Standard"
  tags = var.tags
}

resource "azurerm_firewall_policy" "hub" {
  name = "afwp-hub-${var.env}"
  location = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku = "Basic" # must match with firewall SKU tier
  tags = var.tags
}

resource "azurerm_firewall" "hub" {
  name = "afw-hub-${var.env}"
  location = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku_name = "AZFW_VNet"
  sku_tier = "Basic"
  firewall_policy_id = azurerm_firewall_policy.hub.id
  tags = var.tags

  ip_configuration {
    name = "fw-ipconfig"
    subnet_id = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.fw_data.id
  }

  management_ip_configuration {
    name = "fw-mgmt-ipconfig"
    subnet_id = azurerm_subnet.firewall_mgmt.id
    public_ip_address_id = azurerm_public_ip.fw_mgmt.id
  }
}

# Azure Bastion (basic) - SSH/RDP with no public IPs on our VMs

resource "azurerm_public_ip" "bastion" {
  name = "pip-bastion-${var.env}"
  location = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method = "Static"
  sku = "Standard" # Bastion requires a standard, static IP
  tags = var.tags
}

resource "azurerm_bastion_host" "hub" {
  name = "bas-hub-${var.env}"
  location = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku = "Basic"
  tags = var.tags

  ip_configuration {
    name = "bastion-ipconfig"
    subnet_id = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# VPN gateway - Site-to-Site tunnel between our cloud resources and the simulated datacenter

# Cost note: Basic SKU costs almost $30/mon to support one route-based S2S tunnel with static routing (No BGP, or IKEv2 P2S)
# switch vpn_gateway_sku to "VPNGw1" if later we decided to upgrade for BGP support

locals {
  gw_is_basic = var.vpn_gateway_sku == "Basic"
}

resource "azurerm_public_ip" "vpn_gw" {
  name = "pip-vgw-hub-${var.env}"
  location = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method = local.gw_is_basic ? "Dynamic" : "Static"
  sku = local.gw_is_basic ? "Basic" : "Standard"
  tags = var.tags
}

resource "azurerm_virtual_network_gateway" "hub" {
  name = "vgw-hub-${var.env}"
  location = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  type = "Vpn"
  vpn_type = "RouteBased"
  sku = var.vpn_gateway_sku
  active_active = false 
  # enable_bgp = false 
  tags = var.tags

  ip_configuration {
    name = "vnetGatewyConfig"
    subnet_id = azurerm_subnet.gateway.id
    public_ip_address_id = azurerm_public_ip.vpn_gw.id
    private_ip_address_allocation = "Dynamic"
  }
}
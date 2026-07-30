# On-prem module is meant to simulate a datacenter.

# an isolated Vnet (not peered to azure) with:
# - a StrongSwan VM acting as the on-prem IPsec VPN device (has a public ip)
# - an on-prem 'server' VM on a separate LAN subnet (no public IP)

# its only path to azure is the S2S IPsec tunnel, wired up in the environment root 
# (local network gateway + connection)

resource "azurerm_resource_group" "onprem" {
  name     = "rg-onprem-${var.env}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "onprem" {
  name                = "vnet-onprem-${var.env}"
  location            = azurerm_resource_group.onprem.location
  resource_group_name = azurerm_resource_group.onprem.name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "gateway" {
  name                 = "snet-onprem-gateway"
  resource_group_name  = azurerm_resource_group.onprem.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [var.gateway_subnet_cidr]
}

resource "azurerm_subnet" "lan" {
  name                 = "snet-onprem-lan"
  resource_group_name  = azurerm_resource_group.onprem.name
  virtual_network_name = azurerm_virtual_network.onprem.name
  address_prefixes     = [var.lan_subnet_cidr]
}

# StrongSwan VPN device

resource "azurerm_public_ip" "strongswan" {
  name                = "pip-onprem-vpn-${var.env}"
  location            = azurerm_resource_group.onprem.location
  resource_group_name = azurerm_resource_group.onprem.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_security_group" "strongswan" {
  name                = "nsg-onprem-vpn-${var.env}"
  location            = azurerm_resource_group.onprem.location
  resource_group_name = azurerm_resource_group.onprem.name
  tags                = var.tags

  # IPSec: IKE (500) + NAT-T (4500) inbound from the Azure Gateway IP
  security_rule {
    name                       = "Allow-IPsec"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_ranges    = ["500", "4500"]
    source_address_prefix      = var.azure_gateway_public_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-SSH-from-admin"
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_source_ip   # e.g. "203.0.113.10/32"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "strongswan" {
  name                  = "nic-onprem-vpn-${var.env}"
  location              = azurerm_resource_group.onprem.location
  resource_group_name   = azurerm_resource_group.onprem.name
  ip_forwarding_enabled = true # required so it can route for the LAN
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.gateway.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.strongswan.id
  }
}

resource "azurerm_linux_virtual_machine" "strongswan" {
  name                  = "vm-onprem-vpn-${var.env}"
  location              = azurerm_resource_group.onprem.location
  resource_group_name   = azurerm_resource_group.onprem.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.strongswan.id]
  tags                  = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  custom_data = base64encode(templatefile("${path.module}/templates/strongswan.cloud-init.yaml.tftpl", {
    onprem_gateway_public_ip = azurerm_public_ip.strongswan.ip_address
    azure_gateway_public_ip  = var.azure_gateway_public_ip
    onprem_address_space     = var.address_space
    azure_subnets            = join(",", var.azure_address_spaces)
    vpn_shared_key           = var.vpn_shared_key
  }))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# on-prem 'server' VM - represents a host in the datacenter LAN. No public IP;
# reaches Azure only via the tunnel (default route -> StrongSwan)

resource "azurerm_route_table" "lan" {
  name                = "rt-onprem-lan-${var.env}"
  location            = azurerm_resource_group.onprem.location
  resource_group_name = azurerm_resource_group.onprem.name
  tags                = var.tags

  dynamic "route" {
    for_each = toset(var.azure_address_spaces)
    content {
      name                   = "to-azure-${replace(route.value, "/", "-")}"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = azurerm_network_interface.strongswan.private_ip_address
    }
  }
}

resource "azurerm_subnet_route_table_association" "lan" {
  subnet_id      = azurerm_subnet.lan.id
  route_table_id = azurerm_route_table.lan.id
}

resource "azurerm_network_interface" "lan_vm" {
  name                = "nic-onprem-server-${var.env}"
  location            = azurerm_resource_group.onprem.location
  resource_group_name = azurerm_resource_group.onprem.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.lan.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "lan_vm" {
  name                  = "vm-onprem-server-${var.env}"
  location              = azurerm_resource_group.onprem.location
  resource_group_name   = azurerm_resource_group.onprem.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.lan_vm.id]
  tags                  = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# This is the 'Dev' environment. Composes the hybrid hub-and-spoke topology. 

# hub <--peering(gateway transit)--> spoke-app
#     <--peering(gateway transit)--> spoke-data (+ private-endpoint storage)
#     <--S2S IPsec tunnel-->         on-prem (simualated datacenter)

# See docs/hub-spoke-design.md for the full design and IPAM plan. 

locals {
  # Azure CIDrs reachable from on-prem over the tunnel (hub + both spokes).
  azure_address_spaces = [
    "10.0.0.0/24", # hub
    "10.1.0.0/24", # spoke-app
    "10.2.0.0/24", # spoke-data
  ]
}

# hub

module "hub" {
  source = "../../modules/hub"

  env                  = var.env
  location             = var.location
  address_space        = "10.0.0.0/24"
  vpn_gateway_sku      = var.vpn_gateway_sku
  allowed_egress_fqdns = var.allowed_egress_fqdns
  tags                 = var.tags

  # Lets the Azure Monitor Agent on spoke VMs reach its ingestion endpoints
  # through the forced tunnel. No-op unless VM monitoring is enabled.
  allow_azure_monitor_egress = var.enable_vm_monitoring
}

# Spokes (depend on the hub, so the VPN gateway exists before gateway-transit
# peering is established). 

module "spoke_app" {
  source = "../../modules/spoke"

  name          = "app"
  env           = var.env
  location      = var.location
  address_space = "10.1.0.0/24"
  subnets = {
    "snet-workload" = "10.1.0.0/26"
  }

  firewall_private_ip     = module.hub.firewall_private_ip
  bastion_subnet_cidr     = "10.0.0.64/26"
  hub_vnet_id             = module.hub.vnet_id
  hub_vnet_name           = module.hub.vnet_name
  hub_resource_group_name = module.hub.resource_group_name
  tags                    = var.tags

  depends_on = [module.hub]
}

module "spoke_data" {
  source = "../../modules/spoke"

  name          = "data"
  env           = var.env
  location      = var.location
  address_space = "10.2.0.0/24"
  subnets = {
    "snet-workload"         = "10.2.0.0/26"
    "snet-privateendpoints" = "10.2.0.64/26"
  }

  firewall_private_ip     = module.hub.firewall_private_ip
  bastion_subnet_cidr     = "10.0.0.64/26"
  hub_vnet_id             = module.hub.vnet_id
  hub_vnet_name           = module.hub.vnet_name
  hub_resource_group_name = module.hub.resource_group_name
  tags                    = var.tags

  depends_on = [module.hub]
}

# simulated on-prem datacenter (StrongSwan). Needs the hub gateway's public IP

module "onprem" {
  source = "../../modules/onprem"

  env                     = var.env
  location                = var.location
  address_space           = "192.168.0.0/24"
  azure_gateway_public_ip = module.hub.vpn_gateway_public_ip
  azure_address_spaces    = local.azure_address_spaces
  vpn_shared_key          = var.vpn_shared_key
  admin_username          = var.admin_username
  ssh_public_key          = var.ssh_public_key
  admin_source_ip         = var.admin_source_ip
  tags                    = var.tags

  enable_vm_monitoring    = var.enable_vm_monitoring
  data_collection_rule_id = module.monitoring.data_collection_rule_id
}

# S2S wiring: local network gateway (on-prem representation) + connection. 
# placed in the hub resource group alongside the VPN gateway. 

resource "azurerm_local_network_gateway" "onprem" {
  name                = "lng-onprem-${var.env}"
  location            = var.location
  resource_group_name = module.hub.resource_group_name
  gateway_address     = module.onprem.vpn_device_public_ip
  address_space       = [module.onprem.address_space]
  tags                = var.tags
}

resource "azurerm_virtual_network_gateway_connection" "onprem" {
  name                = "cn-hub-to-onprem-${var.env}"
  location            = var.location
  resource_group_name = module.hub.resource_group_name

  type                       = "IPsec"
  connection_protocol        = "IKEv2"
  virtual_network_gateway_id = module.hub.vpn_gateway_id
  local_network_gateway_id   = azurerm_local_network_gateway.onprem.id
  shared_key                 = var.vpn_shared_key
  tags                       = var.tags
  # No custom ipsec_policy: basic SKU gateways use Azure's default policy
}

# ---------------------------------------------------------------------------
# Monitoring — Log Analytics workspace, diagnostic settings, alerts, budget
# and saved searches all live in the monitoring module (the "Azure Monitor"
# box). See docs/monitoring.md for what is and isn't covered.
#
# It's declared after the storage account only so it can reference its ID;
# Terraform orders the actual creation by dependency, not by position.
# ---------------------------------------------------------------------------
module "monitoring" {
  source = "../../modules/monitoring"

  env      = var.env
  location = var.location
  tags     = var.tags

  firewall_id        = module.hub.firewall_id
  bastion_id         = module.hub.bastion_id
  vpn_gateway_id     = module.hub.vpn_gateway_id
  storage_account_id = azurerm_storage_account.data.id

  alert_email_receivers = var.alert_email_receivers
  monthly_budget_amount = var.monthly_budget_amount
  enable_vm_monitoring  = var.enable_vm_monitoring
}

# The Firewall/Bastion diagnostic settings used to be declared here in the
# root; these keep their state (no destroy/recreate) after the move.
moved {
  from = azurerm_monitor_diagnostic_setting.firewall
  to   = module.monitoring.azurerm_monitor_diagnostic_setting.firewall
}

moved {
  from = azurerm_monitor_diagnostic_setting.bastion
  to   = module.monitoring.azurerm_monitor_diagnostic_setting.bastion
}

# data service - Storage account reachable ONLY over a private endpoint

resource "random_string" "sa_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_storage_account" "data" {
  name                            = "stdata${var.env}${random_string.sa_suffix.result}"
  resource_group_name             = module.spoke_data.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false # private endpoint only
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = module.spoke_data.resource_group_name
  tags                = var.tags
}

# Link the zone to both spokes so either can resolve the private IP
resource "azurerm_private_dns_zone_virtual_network_link" "blob_data" {
  name                  = "link-spoke-data"
  resource_group_name   = module.spoke_data.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = module.spoke_data.vnet_id
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob_app" {
  name                  = "link-spoke-app"
  resource_group_name   = module.spoke_data.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = module.spoke_app.vnet_id
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-stdata-${var.env}"
  location            = var.location
  resource_group_name = module.spoke_data.resource_group_name
  subnet_id           = module.spoke_data.subnet_ids["snet-privateendpoints"]
  tags                = var.tags

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.data.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

# workload VMs - one per spokes, no public IPs (admin access via Bastion). 
# they exist purely to generate traffic for the reachability/inspection demos

resource "azurerm_network_interface" "app" {
  name                = "nic-app-${var.env}"
  location            = var.location
  resource_group_name = module.spoke_app.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = module.spoke_app.workload_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "app" {
  name                  = "vm-app-${var.env}"
  location              = var.location
  resource_group_name   = module.spoke_app.resource_group_name
  size                  = "Standard_B1s"
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.app.id]
  tags                  = var.tags

  # System-assigned identity so the Azure Monitor Agent can authenticate.
  identity {
    type = "SystemAssigned"
  }

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

resource "azurerm_network_interface" "data" {
  name                = "nic-data-${var.env}"
  location            = var.location
  resource_group_name = module.spoke_data.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = module.spoke_data.workload_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "data" {
  name                  = "vm-data-${var.env}"
  location              = var.location
  resource_group_name   = module.spoke_data.resource_group_name
  size                  = "Standard_B1s"
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.data.id]
  tags                  = var.tags

  # System-assigned identity so the Azure Monitor Agent can authenticate.
  identity {
    type = "SystemAssigned"
  }

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

# ---------------------------------------------------------------------------
# Guest monitoring for the spoke VMs (opt-in via enable_vm_monitoring).
# Azure Monitor Agent + association to the Linux Data Collection Rule, which
# ships syslog + perf counters (and a Heartbeat) to Log Analytics.
# ---------------------------------------------------------------------------

locals {
  monitored_vms = var.enable_vm_monitoring ? {
    app  = azurerm_linux_virtual_machine.app.id
    data = azurerm_linux_virtual_machine.data.id
  } : {}
}

resource "azurerm_virtual_machine_extension" "ama" {
  for_each = local.monitored_vms

  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = each.value
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  tags                       = var.tags
}

resource "azurerm_monitor_data_collection_rule_association" "vm" {
  for_each = local.monitored_vms

  name                    = "dcra-${each.key}-${var.env}"
  target_resource_id      = each.value
  data_collection_rule_id = module.monitoring.data_collection_rule_id
}

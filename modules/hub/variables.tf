variable "env" {
  description = "Environment slug (e.g. dev, prod)."
  type = string
}

variable "location" {
  description = "Azure region."
  type = string
}

variable "address_space" {
    description = "Hub VNet CIDR range."
    type = string
    default = "10.0.0.0/24"
}

variable "firewall_subnet_cidr" {
  description = "CIDR for AzureFirewallSubnet."
  type = string
  default = "10.0.0.0/26"
}

variable "firewall_mgmt_subnet_cidr" {
  description = "CIDR for AzureFirewallManagementSubnet (required by Firewall Basic)."
  type = string
  default = "10.0.0.192/26"
}

variable "bastion_subnet_cidr" {
  description = "CIDR for AzureBastionSubnet (must be /26 or larger)."
  type = string
  default = "10.0.0.64/26"
}

variable "gateway_subnet_cidr" {
  description = "CIDR for GatewaySubnet (must be /27 or larger)."
  type = string
  default = "10.0.0.128/27"
}

variable "vpn_gateway_sku" {
  description = "VPN Gateway SKU. 'Basic' is cheapest (static routing only); 'VpnGw1' adds BGP + P2S support."
  type = string
  default = "Basic"
}

variable "tags" {
  description = "Tags applied to hub resources."
  type = map(string)
  default = {}
}
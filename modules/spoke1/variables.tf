variable "name" {
  description = "Spoke short name (e.g. app, data)."
  type = string
}

variable "env" {
  description = "Environment slug (e.g. dev, prod)."
  type = string
}

variable "location" {
  description = "Azure region."
  type = string
}

variable "address_space" {
  description = "Spoke one VNet CIDR."
  type = string
}

variable "subnets" {
  description = "Map of subnet name => CIDR for this spoke."
  type = map(string)
}

variable "workload_subnet_name" {
  description = "Which subnet (key in var.subnets) gets the NSG + route table."
  type = string
  default = "snet-workload"
}

variable "firewall_private_ip" {
  description = "Hub firewall private IP (UDR next hop)."
  type = string
}

variable "bastion_subnet_cidr" {
  description = "Hub AzureBastionSubnet CIDR, for the NSG allow rule."
  type = string
}

variable "hub_vnet_id" {
  description = "Hub Vnet ID (for spoke-to-hub peering)."
  type = string
}

variable "hub_vnet_name" {
  description = "Hub Vnet name (for hub-to-spoke peering)."
  type = string
}

variable "hub_resource_group_name" {
  description = "Hub resource group name (for hub-to-spoke peering)."
  type = string
}

variable "use_remote_gateways" {
  description = "Whether this spoke uses the hub's VPN gateway (gateway transit). Set false until the gateway exists."
  type = bool
  default = true
}

variable "tags" {
  description = "Tags applied to spoke resources."
  type = map(string)
  default = {}
}


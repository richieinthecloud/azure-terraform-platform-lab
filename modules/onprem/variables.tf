variable "env" {
  description = "Environment slug (e.g. dev, prod)."
  type        = string
}

variable "location" {
  description = "Azure region for the simulated datacenter."
  type        = string
}

variable "address_space" {
  description = "On-prem VNet CIDR (deliberary non-10.x to read as a separate site)."
  type        = string
  default     = "192.168.0.0/24"
}

variable "gateway_subnet_cidr" {
  description = "Subnet for the StrongSwan VPN device."
  type        = string
  default     = "192.168.0.0/26"
}

variable "lan_subnet_cidr" {
  description = "Subnet for the on-prem server VM."
  type        = string
  default     = "192.168.0.64/26"
}

variable "azure_gateway_public_ip" {
  description = "Public IP of the Azure VPN gateway (StrongSwan peers to this)."
  type        = string
}

variable "azure_address_spaces" {
  description = "Azure CIDRs reachable over the tunnel (hub + spokes)."
  type        = list(string)
}

variable "vpn_shared_key" {
  description = "Pre-shared key for the S2S tunnel. Pass via TF_VAR / tfvars, never commit."
  type        = string
  sensitive   = true
}

variable "admin_username" {
  description = "Admin username for the on-prem VMs."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key for the on-prem VMs."
  type        = string
}

variable "vm_size" {
  description = "VM size for the on-prem VMs"
  type        = string
  default     = "Standard_B1s"
}

variable "admin_source_ip" {
  description = "Source IP of the device trying to SSH into the on-prem VM."
  type        = string
}

variable "tags" {
  description = "Tags applied to on-prem resources."
  type        = map(string)
  default     = {}
}

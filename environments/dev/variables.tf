
variable "location" {
  description = "Azure region for the dev environment."
  type        = string
  default     = "eastus"
}

variable "env" {
  description = "Environment slug."
  type        = string
  default     = "dev"
}

variable "vpn_gateway_sku" {
  description = "VPN Gateway SKU (Basic = cheapest; VpnGw1 for BGP/P2S)."
  type        = string
  default     = "Basic"
}

variable "vpn_shared_key" {
  description = "Pre-shared key for the S2S tunnel. Set via TF_VAR_vpn_shared_key or a git-ignored .tfvars."
  type        = string
  sensitive   = true
}

variable "admin_username" {
  description = "Admin username for lab VMs."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key used for all lab VMs."
  type        = string
}

variable "admin_source_ip" {
  description = "Source IP of the device trying to SSH into the on-prem VM."
  type        = string
}

variable "allowed_egress_fqdns" {
  description = "Approved outbound FQDNs for the dev firewall."
  type        = list(string)
  default     = ["azure.archive.ubuntu.com", "security.ubuntu.com", "github.com"]
}

variable "alert_email_receivers" {
  description = "Email addresses for alert + budget notifications. Leave empty for portal-only alerts."
  type        = list(string)
  default     = []
}

variable "monthly_budget_amount" {
  description = "Monthly subscription budget for the cost alert (billing currency). 0 disables it."
  type        = number
  default     = 100
}

variable "enable_vm_monitoring" {
  description = "Install the Azure Monitor Agent on lab VMs (syslog + perf + heartbeat) and open AzureMonitor egress on the firewall. Adds a little ingestion cost."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Base tags for all dev resources."
  type        = map(string)
  default = {
    environment = "dev"
    project     = "azure-terraform-platform-lab"
    owner       = "richieinthecloud"
    managed_by  = "terraform"
  }
}

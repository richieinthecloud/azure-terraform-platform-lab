variable "env" {
  description = "Environment slug (e.g. dev, prod)."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "retention_in_days" {
  description = "Log Analytics retention. 30 is the free-tier minimum; raise for longer history."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to monitoring resources."
  type        = map(string)
  default     = {}
}

# --- what to monitor -------------------------------------------------------

variable "firewall_id" {
  description = "Azure Firewall resource ID (diagnostic settings + health/SNAT alerts)."
  type        = string
}

variable "bastion_id" {
  description = "Azure Bastion resource ID (diagnostic settings)."
  type        = string
}

variable "vpn_gateway_id" {
  description = "VPN Gateway resource ID (diagnostic settings; source of the tunnel-down alert)."
  type        = string
}

variable "enable_storage_logs" {
  description = "Stream blob-service logs/metrics from storage_account_id into the workspace."
  type        = bool
  default     = true
}

variable "storage_account_id" {
  description = "Storage account resource ID whose blob service should log to the workspace. Required when enable_storage_logs is true."
  type        = string
  default     = null
}

variable "enable_activity_log" {
  description = "Stream the subscription Activity Log into the workspace (needs Microsoft.Insights/diagnosticSettings/write at subscription scope)."
  type        = bool
  default     = true
}

variable "enable_vm_monitoring" {
  description = "Create the Linux Data Collection Rule + VM heartbeat alert. The caller must also attach the Azure Monitor Agent to each VM and allow AzureMonitor egress through the firewall."
  type        = bool
  default     = false
}

# --- who gets told ---------------------------------------------------------

variable "alert_email_receivers" {
  description = "Email addresses that receive alert + budget notifications. Empty list = portal only."
  type        = list(string)
  default     = []
}

# --- thresholds ------------------------------------------------------------

variable "firewall_deny_threshold" {
  description = "Number of firewall Deny events in 15 minutes that triggers the (severity 3) alert."
  type        = number
  default     = 50
}

variable "monthly_budget_amount" {
  description = "Monthly subscription budget (in the subscription's billing currency) for the cost alert. 0 disables the budget."
  type        = number
  default     = 100
}

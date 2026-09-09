# Monitoring module
#
# One place for everything "Azure Monitor" in this lab:
#   - the Log Analytics workspace (the sink)
#   - diagnostic settings that stream platform logs/metrics into it
#   - an action group (who gets told) + a small set of alerts (what we watch)
#   - a monthly budget so a forgotten VPN gateway can't quietly burn money
#   - saved KQL searches so the interesting questions are one click away
#
# Resource IDs of the things to monitor are passed in from the environment
# root, so this module knows nothing about how the hub/spokes are built.

data "azurerm_client_config" "current" {}

locals {
  subscription_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
}

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "monitoring" {
  name     = "rg-monitoring-${var.env}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-hubspoke-${var.env}"
  location            = azurerm_resource_group.monitoring.location
  resource_group_name = azurerm_resource_group.monitoring.name
  sku                 = "PerGB2018"           # standard pay-per-GB tier
  retention_in_days   = var.retention_in_days # 30 days is the free minimum
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Diagnostic settings — platform logs + metrics -> workspace.
# Diagnostic settings themselves are free; you pay for ingested GB only.
#
# "allLogs" captures every log category the resource supports, so these keep
# working as Azure adds/renames categories.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                       = "diag-firewall"
  target_resource_id         = var.firewall_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "bastion" {
  name                       = "diag-bastion"
  target_resource_id         = var.bastion_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  # NOTE: BastionAuditLogs require the Standard SKU. On Basic Bastion this
  # setting still deploys but emits little/no log data (metrics only).
  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# The VPN gateway is the whole point of the hybrid demo and was previously
# unmonitored. This gives us GatewayDiagnosticLog, TunnelDiagnosticLog,
# IKEDiagnosticLog and RouteDiagnosticLog (all land in AzureDiagnostics).
resource "azurerm_monitor_diagnostic_setting" "vpn_gateway" {
  name                       = "diag-vpn-gateway"
  target_resource_id         = var.vpn_gateway_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Blob-service logs prove the "private-endpoint-only" story: every request
# shows up in StorageBlobLogs with the caller's private IP.
resource "azurerm_monitor_diagnostic_setting" "storage_blob" {
  # A bool flag, not a null-check on the ID: the ID is unknown until apply on
  # a fresh deploy, and count must be known at plan time.
  count = var.enable_storage_logs ? 1 : 0

  name                       = "diag-storage-blob"
  target_resource_id         = "${var.storage_account_id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "Transaction"
  }

  enabled_metric {
    category = "Capacity"
  }
}

# Subscription Activity Log -> workspace, so control-plane changes (who
# ran terraform apply, what the pipeline touched, service-health events)
# are queryable next to the data-plane logs.
resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  count = var.enable_activity_log ? 1 : 0

  name                       = "diag-activity-log-${var.env}"
  target_resource_id         = local.subscription_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  # Activity Log doesn't support category groups; list every category so
  # the provider doesn't see a perpetual diff.
  dynamic "enabled_log" {
    for_each = toset([
      "Administrative",
      "Security",
      "ServiceHealth",
      "Alert",
      "Recommendation",
      "Policy",
      "Autoscale",
      "ResourceHealth",
    ])
    content {
      category = enabled_log.value
    }
  }
}

# ---------------------------------------------------------------------------
# Action group — where alerts go. Email receivers are optional; with none
# configured, alerts still show up in the portal (Monitor > Alerts).
# ---------------------------------------------------------------------------

resource "azurerm_monitor_action_group" "platform" {
  name                = "ag-platform-${var.env}"
  resource_group_name = azurerm_resource_group.monitoring.name
  short_name          = "plat-${var.env}" # max 12 chars
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = { for i, e in var.alert_email_receivers : tostring(i) => e }
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

# ---------------------------------------------------------------------------
# Alerts
#   Metric alerts   ~ $0.10/month each
#   Log alerts      ~ $0.50/month each at a 15-minute cadence
#   Activity-log alerts are free
# ---------------------------------------------------------------------------

# Firewall reports its own health as a percentage; anything under 100 means
# an instance is unhealthy (and with Basic there is only one instance).
resource "azurerm_monitor_metric_alert" "firewall_health" {
  name                = "alert-firewall-health-${var.env}"
  resource_group_name = azurerm_resource_group.monitoring.name
  scopes              = [var.firewall_id]
  description         = "Azure Firewall health dropped below 100% (an instance is degraded or unhealthy)."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"
  auto_mitigate       = true
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Network/azureFirewalls"
    metric_name      = "FirewallHealth"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 100
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

# Egress from every spoke is SNAT'd by the firewall's single public IP.
# Running out of SNAT ports looks like "random" connection failures.
resource "azurerm_monitor_metric_alert" "firewall_snat" {
  name                = "alert-firewall-snat-${var.env}"
  resource_group_name = azurerm_resource_group.monitoring.name
  scopes              = [var.firewall_id]
  description         = "Azure Firewall SNAT port utilization above 80%."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  auto_mitigate       = true
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Network/azureFirewalls"
    metric_name      = "SNATPortUtilization"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

# S2S tunnel down. Basic SKU gateways have no BGP/peer metrics, so we use the
# TunnelDiagnosticLog state feed: latest status per tunnel == Disconnected.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "vpn_tunnel_down" {
  name                = "alert-vpn-tunnel-down-${var.env}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = var.location
  description         = "Site-to-Site IPsec tunnel to on-prem reports Disconnected."
  severity            = 1
  enabled             = true
  tags                = var.tags

  scopes                    = [azurerm_log_analytics_workspace.this.id]
  evaluation_frequency      = "PT15M"
  window_duration           = "PT15M"
  query_time_range_override = "P1D" # tunnel may have gone down hours ago; look at the latest state
  auto_mitigation_enabled   = true

  # The AzureDiagnostics table (and its columns) only exist once the first
  # log arrives, so validation at create time would fail on a fresh workspace.
  skip_query_validation = true

  criteria {
    query                   = <<-KQL
      AzureDiagnostics
      | where ResourceType == "VIRTUALNETWORKGATEWAYS" and Category == "TunnelDiagnosticLog"
      | summarize arg_max(TimeGenerated, status_s, stateChangeReason_s) by Resource, instance_s, remoteIP_s
      | where status_s == "Disconnected"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.platform.id]
  }
}

# Firewall denies spiking — usually a workload trying to reach something
# that isn't on the FQDN allow-list (or something probing east-west).
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "firewall_denies" {
  name                = "alert-firewall-denies-${var.env}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = var.location
  description         = "Azure Firewall denied more than ${var.firewall_deny_threshold} flows in 15 minutes."
  severity            = 3
  enabled             = true
  tags                = var.tags

  scopes                  = [azurerm_log_analytics_workspace.this.id]
  evaluation_frequency    = "PT15M"
  window_duration         = "PT15M"
  auto_mitigation_enabled = true
  skip_query_validation   = true

  criteria {
    query                   = <<-KQL
      AzureDiagnostics
      | where ResourceType == "AZUREFIREWALLS"
      | where Category in ("AzureFirewallNetworkRule", "AzureFirewallApplicationRule")
      | where msg_s has "Deny"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = var.firewall_deny_threshold
  }

  action {
    action_groups = [azurerm_monitor_action_group.platform.id]
  }
}

# Azure-side platform problems that aren't our fault but still take the lab
# down: regional incidents (Service Health) and per-resource health.
resource "azurerm_monitor_activity_log_alert" "service_health" {
  name                = "alert-service-health-${var.env}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = "global"
  scopes              = [local.subscription_id]
  description         = "Azure Service Health incident/maintenance/advisory affecting this subscription."
  tags                = var.tags

  criteria {
    category = "ServiceHealth"
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

resource "azurerm_monitor_activity_log_alert" "resource_health" {
  name                = "alert-resource-health-${var.env}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = "global"
  scopes              = [local.subscription_id]
  description         = "A resource in this subscription became Degraded or Unavailable."
  tags                = var.tags

  criteria {
    category = "ResourceHealth"

    resource_health {
      current = ["Degraded", "Unavailable"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

# ---------------------------------------------------------------------------
# Budget — this is a self-funded lab; the VPN gateway + firewall bill even
# when idle. Fires at 80% actual and 100% forecasted spend.
# ---------------------------------------------------------------------------

resource "azurerm_consumption_budget_subscription" "lab" {
  count = var.monthly_budget_amount > 0 ? 1 : 0

  name            = "budget-hubspoke-${var.env}"
  subscription_id = local.subscription_id
  amount          = var.monthly_budget_amount
  time_grain      = "Monthly"

  time_period {
    # Budgets must start on the 1st of a month. Pin the month the budget was
    # created and ignore it afterwards so each plan doesn't try to move it.
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    operator       = "GreaterThan"
    threshold      = 80
    threshold_type = "Actual"
    contact_groups = [azurerm_monitor_action_group.platform.id]
    contact_emails = length(var.alert_email_receivers) > 0 ? var.alert_email_receivers : null
  }

  notification {
    enabled        = true
    operator       = "GreaterThan"
    threshold      = 100
    threshold_type = "Forecasted"
    contact_groups = [azurerm_monitor_action_group.platform.id]
    contact_emails = length(var.alert_email_receivers) > 0 ? var.alert_email_receivers : null
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}

# ---------------------------------------------------------------------------
# VM guest monitoring (opt-in) — a Data Collection Rule the Azure Monitor
# Agent uses to ship syslog + perf counters here. The agent extension itself
# is attached per-VM by the caller (it needs the VM resource IDs).
# ---------------------------------------------------------------------------

resource "azurerm_monitor_data_collection_rule" "linux" {
  count = var.enable_vm_monitoring ? 1 : 0

  name                = "dcr-linux-${var.env}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  kind                = "Linux"
  description         = "Syslog + basic perf counters from lab VMs (incl. StrongSwan/charon IPsec logs)."
  tags                = var.tags

  destinations {
    log_analytics {
      name                  = "law"
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
    }
  }

  data_sources {
    # daemon = StrongSwan/charon; auth/authpriv = SSH logins via Bastion.
    syslog {
      name           = "syslog"
      streams        = ["Microsoft-Syslog"]
      facility_names = ["auth", "authpriv", "daemon", "kern", "syslog"]
      log_levels     = ["Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
    }

    performance_counter {
      name                          = "perf"
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers = [
        "Processor(*)\\% Processor Time",
        "Memory(*)\\% Used Memory",
        "Logical Disk(*)\\% Used Space",
        "Network(*)\\Total Bytes Transmitted",
        "Network(*)\\Total Bytes Received",
      ]
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog", "Microsoft-Perf"]
    destinations = ["law"]
  }
}

# A VM that stops heartbeating is off, wedged, or lost its egress path
# (which, behind a forced-tunnel firewall, is a routing bug worth knowing about).
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "vm_heartbeat" {
  count = var.enable_vm_monitoring ? 1 : 0

  name                = "alert-vm-heartbeat-${var.env}"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = var.location
  description         = "A lab VM has not sent an Azure Monitor Agent heartbeat in the last 10 minutes."
  severity            = 2
  enabled             = true
  tags                = var.tags

  scopes                    = [azurerm_log_analytics_workspace.this.id]
  evaluation_frequency      = "PT15M"
  window_duration           = "PT15M"
  query_time_range_override = "P1D"
  auto_mitigation_enabled   = true
  skip_query_validation     = true

  criteria {
    query                   = <<-KQL
      Heartbeat
      | summarize LastHeartbeat = max(TimeGenerated) by Computer
      | where LastHeartbeat < ago(10m)
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.platform.id]
  }
}

# ---------------------------------------------------------------------------
# Saved searches — the questions this lab exists to answer, pre-written.
# Portal: Log Analytics workspace > Logs > Queries > "Hub-Spoke Lab".
# ---------------------------------------------------------------------------

locals {
  saved_searches = {
    "fw-denied-flows" = {
      display_name = "Firewall: denied flows (last 24h)"
      query        = <<-KQL
        AzureDiagnostics
        | where TimeGenerated > ago(24h)
        | where ResourceType == "AZUREFIREWALLS"
        | where Category in ("AzureFirewallNetworkRule", "AzureFirewallApplicationRule")
        | where msg_s has "Deny"
        | project TimeGenerated, Category, msg_s
        | order by TimeGenerated desc
      KQL
    }
    "fw-top-fqdns" = {
      display_name = "Firewall: top egress FQDNs by action"
      query        = <<-KQL
        AzureDiagnostics
        | where TimeGenerated > ago(24h)
        | where ResourceType == "AZUREFIREWALLS" and Category == "AzureFirewallApplicationRule"
        | parse msg_s with Protocol " request from " SourceIp ":" SourcePort " to " Fqdn ":" DestPort ". Action: " Action "." *
        | summarize Hits = count() by Fqdn, Action
        | top 25 by Hits
      KQL
    }
    "fw-east-west" = {
      display_name = "Firewall: east-west (spoke-to-spoke / on-prem) flows"
      query        = <<-KQL
        AzureDiagnostics
        | where TimeGenerated > ago(24h)
        | where ResourceType == "AZUREFIREWALLS" and Category == "AzureFirewallNetworkRule"
        | parse msg_s with Protocol " request from " SourceIp ":" SourcePort " to " DestIp ":" DestPort ". Action: " Action "." *
        | where ipv4_is_private(SourceIp) and ipv4_is_private(DestIp)
        | summarize Flows = count() by SourceIp, DestIp, DestPort, Action
        | order by Flows desc
      KQL
    }
    "vpn-tunnel-state" = {
      display_name = "VPN: S2S tunnel state changes"
      query        = <<-KQL
        AzureDiagnostics
        | where TimeGenerated > ago(7d)
        | where ResourceType == "VIRTUALNETWORKGATEWAYS" and Category == "TunnelDiagnosticLog"
        | project TimeGenerated, Resource, instance_s, remoteIP_s, status_s, stateChangeReason_s
        | order by TimeGenerated desc
      KQL
    }
    "vpn-ike-events" = {
      display_name = "VPN: IKE negotiation log (troubleshooting)"
      query        = <<-KQL
        AzureDiagnostics
        | where TimeGenerated > ago(24h)
        | where ResourceType == "VIRTUALNETWORKGATEWAYS" and Category == "IKEDiagnosticLog"
        | project TimeGenerated, Resource, remoteIP_s, localIP_s, Message
        | order by TimeGenerated desc
      KQL
    }
    "storage-private-access" = {
      display_name = "Storage: blob requests by caller IP (proves private-endpoint path)"
      query        = <<-KQL
        StorageBlobLogs
        | where TimeGenerated > ago(24h)
        | summarize Requests = count() by CallerIpAddress, OperationName, StatusText, AuthenticationType
        | order by Requests desc
      KQL
    }
    "activity-admin-ops" = {
      display_name = "Activity Log: who changed what (Administrative)"
      query        = <<-KQL
        AzureActivity
        | where TimeGenerated > ago(7d)
        | where CategoryValue == "Administrative" and ActivityStatusValue in ("Success", "Failure")
        | project TimeGenerated, Caller, OperationNameValue, ActivityStatusValue, ResourceGroup, _ResourceId
        | order by TimeGenerated desc
      KQL
    }
    "vm-strongswan-syslog" = {
      display_name = "VMs: StrongSwan (charon) IPsec syslog — needs enable_vm_monitoring"
      query        = <<-KQL
        Syslog
        | where TimeGenerated > ago(24h)
        | where ProcessName has "charon" or ProcessName has "ipsec"
        | project TimeGenerated, Computer, Facility, SeverityLevel, SyslogMessage
        | order by TimeGenerated desc
      KQL
    }
    "vm-ssh-logins" = {
      display_name = "VMs: SSH logins via Bastion — needs enable_vm_monitoring"
      query        = <<-KQL
        Syslog
        | where TimeGenerated > ago(7d)
        | where ProcessName == "sshd" and SyslogMessage has_any ("Accepted", "Failed")
        | project TimeGenerated, Computer, SyslogMessage
        | order by TimeGenerated desc
      KQL
    }
  }
}

resource "azurerm_log_analytics_saved_search" "this" {
  for_each = local.saved_searches

  name                       = each.key
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  category                   = "Hub-Spoke Lab"
  display_name               = each.value.display_name
  query                      = each.value.query
  tags                       = var.tags
}

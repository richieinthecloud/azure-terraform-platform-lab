# Monitoring — current coverage and improvement plan

This document answers two questions about the `dev` environment:

1. **What is being monitored today, and what isn't?**
2. **What's the plan to close the gaps, in what order, and what does it cost?**

Everything described under *Phase 1* and *Phase 2* is implemented in
`modules/monitoring` and wired up in `environments/dev`. Later phases are
documented decisions, not code yet.

---

## 1. Coverage audit

### Before this change (baseline)

The original monitoring footprint was a single Log Analytics workspace with
two diagnostic settings, and nothing that would ever *tell* anyone anything.

| Resource | Logs to LAW | Metrics to LAW | Alerts | Notes |
|---|:-:|:-:|:-:|---|
| Azure Firewall (`afw-hub-dev`) | ✅ `allLogs` | ✅ | ❌ | Rule hits / denies visible only if you go looking |
| Azure Bastion (`bas-hub-dev`) | ⚠️ | ✅ | ❌ | Basic SKU emits **no** `BastionAuditLogs`; setting is effectively metrics-only |
| VPN Gateway (`vgw-hub-dev`) | ❌ | ❌ | ❌ | **The hybrid link — the headline demo — was completely dark** |
| S2S connection (`cn-hub-to-onprem-dev`) | n/a | ❌ | ❌ | Connection status only visible in the portal blade |
| Local network gateway | n/a | n/a | n/a | Static config, nothing to monitor |
| Storage account (private endpoint) | ❌ | ❌ | ❌ | No evidence trail that access really comes via the PE |
| Private endpoint / Private DNS zone | ❌ | ❌ | ❌ | PE has no diag categories; DNS zone metrics exist but weren't collected |
| Spoke VMs (`vm-app`, `vm-data`) | ❌ | host metrics only¹ | ❌ | No agent → no syslog, no heartbeat, no guest perf |
| On-prem StrongSwan VM | ❌ | host metrics only¹ | ❌ | `charon` IPsec negotiation logs stayed on the box |
| On-prem LAN VM | ❌ | host metrics only¹ | ❌ | |
| NSGs (spoke workload, on-prem VPN) | ❌ | n/a | ❌ | No flow logs; NSG counter metrics not collected |
| Route tables / UDRs / peerings | n/a | n/a | ❌ | No native telemetry; correctness only provable via firewall logs or flow logs |
| Subscription Activity Log | ❌ | n/a | ❌ | No record of *who* changed *what* (pipeline vs. human) |
| Azure Service Health / Resource Health | — | — | ❌ | Regional incidents would go unnoticed |
| Cost / budget | — | — | ❌ | Self-funded lab with a VPN gateway and firewall billing 24×7, no guard-rail |
| Notification channel (action group) | — | — | ❌ | Did not exist |
| `prod` environment | — | — | — | Empty scaffold; nothing deployed, nothing monitored |

¹ Azure always records platform host metrics (CPU %, network in/out, disk ops)
for every VM in Azure Monitor Metrics for free, but nothing was alerting on
them and nothing was landing in the workspace.

**Summary of the baseline:** logs were being *collected* for two hub services
and *nobody was watching*. There was no alerting, no notification path, no
budget, no VPN telemetry, no VM guest telemetry, and no control-plane audit
trail.

### After this change (Phase 1 + opt-in Phase 2)

| Resource | Logs | Metrics | Alert | How |
|---|:-:|:-:|:-:|---|
| Azure Firewall | ✅ | ✅ | ✅ health < 100 % (sev 1), SNAT > 80 % (sev 2), deny spike (sev 3) | diag setting + 2 metric alerts + 1 log alert |
| Azure Bastion | ⚠️ (SKU) | ✅ | ❌ | unchanged; see *Phase 3* |
| VPN Gateway | ✅ Gateway/Tunnel/IKE/Route logs | ✅ | ✅ tunnel `Disconnected` (sev 1) | diag setting + log alert on `TunnelDiagnosticLog` |
| Storage (blob service) | ✅ read/write/delete | ✅ Transaction + Capacity | ❌ | diag setting on `blobServices/default` |
| Subscription Activity Log | ✅ all 8 categories | n/a | ✅ Service Health, Resource Health (Degraded/Unavailable) | subscription diag setting + 2 activity-log alerts |
| Cost | — | — | ✅ 80 % actual, 100 % forecast | subscription budget |
| Spoke VMs + StrongSwan VM | ✅ syslog (auth/daemon/kern…) | ✅ CPU/mem/disk/net | ✅ heartbeat missing > 10 min | **opt-in** `enable_vm_monitoring = true` |
| On-prem LAN VM | ❌ | host only | ❌ | can't reach Azure Monitor (no internet path); see *Phase 3* |
| NSG / VNet flow logs | ❌ | ❌ | ❌ | *Phase 3* |
| Notification channel | — | — | ✅ | action group `ag-platform-dev` (email receivers optional) |
| Saved queries | 9 KQL saved searches under category **Hub-Spoke Lab** | | | |

---

## 2. The plan

Ordered by *value ÷ (cost + risk)*. Phases 1–2 are done; 3–4 are the roadmap.

### Phase 1 — free/cheap platform telemetry + a way to be told ✅ *implemented*

| # | Change | Why | Cost |
|---|---|---|---|
| 1.1 | Move diagnostic settings into `modules/monitoring` (with `moved {}` blocks so state is preserved) | One module owns "observability"; `prod` gets it for free by calling the same module | — |
| 1.2 | **VPN Gateway diagnostics** (`allLogs` + `AllMetrics`) | The hybrid tunnel was the only unmonitored piece of the architecture that matters | ingestion only (tiny) |
| 1.3 | **Storage blob diagnostics** | `StorageBlobLogs.CallerIpAddress` is the proof that traffic arrives via the private endpoint (10.2.0.x) and not the public plane | ingestion only |
| 1.4 | **Activity Log → workspace** | Audit trail of every `terraform apply` (pipeline SP vs. human), plus ServiceHealth events, queryable in KQL | free (Activity Log ingestion is not billed) |
| 1.5 | **Action group** with optional email receivers | Alerts are pointless without a destination; leaving receivers empty still surfaces them in *Monitor › Alerts* | free |
| 1.6 | **Alerts** — firewall health, SNAT utilisation, deny spike, tunnel disconnected, Service Health, Resource Health | The six things that actually take this lab down | ≈ $1.20/month total |
| 1.7 | **Monthly budget** (80 % actual, 100 % forecast) | Self-funded lab; the gateway + firewall bill even when idle | free |
| 1.8 | **Saved searches** | The demo questions ("show me a deny", "show me the tunnel flap", "prove the PE path") become one click | free |

**Inputs you should set** (in `terraform.tfvars`, see `terraform.tfvars.example`):

```hcl
alert_email_receivers = ["you@example.com"]
monthly_budget_amount = 100
```

### Phase 2 — guest-level VM telemetry ✅ *implemented, opt-in*

Set `enable_vm_monitoring = true` and apply. This adds:

- a **Linux Data Collection Rule** (`dcr-linux-dev`) collecting syslog
  (`auth`, `authpriv`, `daemon`, `kern`, `syslog` at Info+) and five perf
  counters every 60 s;
- the **Azure Monitor Agent** extension + DCR association on `vm-app`,
  `vm-data` and the **StrongSwan VM** (system-assigned identities are always
  on, so flipping the flag only adds the extensions);
- a firewall **network rule** allowing TCP/443 from internal ranges to the
  `AzureMonitor` service tag, because the spoke VMs are forced-tunnelled and
  would otherwise never reach the ingestion endpoints;
- a **heartbeat alert** (sev 2) when any agent goes quiet for 10 minutes.

Why it's opt-in rather than default: it is the first change that installs
software *inside* the VMs and widens the firewall allow-list, and the AMA
install needs the VMs to be running and able to egress. Turn it on once, watch
the `Heartbeat` table populate, and it can become the default.

What you get: `charon` IPsec logs from the on-prem side of the tunnel
(`Syslog | where ProcessName has "charon"`), SSH login audit for Bastion
sessions (`sshd` in syslog) — which is what Basic Bastion can't give you —
and guest CPU/memory/disk for the B1s VMs.

Cost: ingestion, roughly 50–150 MB/day across three idle VMs ≈ **$0.15–0.40/day**;
plus one log alert ≈ $0.50/month.

**Known limitation:** the on-prem **LAN VM** is deliberately excluded. Its
default route is the StrongSwan box, which forwards to Azure over the tunnel
but does not NAT to the internet, so the agent could never reach Azure
Monitor. Options: (a) add a `MASQUERADE` rule to the StrongSwan cloud-init,
(b) accept it — in a real datacenter that host would report to an on-prem
collector anyway.

### Phase 3 — network flow visibility and Bastion audit 🔜 *planned*

| # | Change | Why | Cost / caveat |
|---|---|---|---|
| 3.1 | **VNet flow logs** (`azurerm_network_watcher_flow_log` with `target_resource_id` = each VNet) → storage account, optionally Traffic Analytics → workspace | The only way to *see* that east-west traffic really transits the firewall and that the UDR isn't being bypassed. NSG flow logs are retired for new deployments (no new ones after June 2025), so use VNet flow logs. | storage ≈ pennies; Traffic Analytics ≈ $2–3/GB processed; needs the region's `NetworkWatcher_eastus` resource (auto-created on first VNet unless the subscription disabled it) |
| 3.2 | **Bastion Standard SKU** | Unlocks `BastionAuditLogs` (who connected to which VM, when). Basic emits nothing. | ≈ +$0.19/h (~$140/mo) — probably **not worth it** for a lab; Phase 2's sshd syslog covers the same question for ~free |
| 3.3 | **Private DNS zone metrics** (`QueryVolume`, `RecordSetCount`) → workspace | Confirms spoke VMs are resolving via the private zone | free |
| 3.4 | **Workbook** (`azurerm_application_insights_workbook`) pinning the saved searches into one "lab health" page: tunnel state, top FQDNs, denies, VM heartbeat, spend | Demo-ready single pane; replaces the per-query clicking | free |

### Phase 4 — pipeline & governance 🔜 *planned*

| # | Change | Why |
|---|---|---|
| 4.1 | Apply-workflow failure → GitHub issue / action-group webhook | Right now a failed `terraform apply` on `main` is only visible in the Actions tab |
| 4.2 | **Azure Policy** "deploy diagnostic settings if not exists" for the resource types used here | Catches any resource added later without going through the module |
| 4.3 | Alert on Activity Log **writes by a non-pipeline caller** (`Caller != <pipeline SP>`) | Detects out-of-band portal changes (drift) |
| 4.4 | `prod` environment composes `modules/monitoring` with `retention_in_days = 90` and its own budget | Same coverage as dev; longer retention costs ≈ $0.10/GB/month beyond 31 days |

---

## 3. Cost summary (dev, default settings)

| Item | Monthly |
|---|---|
| Log Analytics ingestion — firewall + gateway + storage + activity log on an idle lab | ≈ $0.50–2 (Activity Log is free; everything else bills at ~$2.30/GB on `PerGB2018`) |
| 2 metric alerts | ≈ $0.20 |
| 2 log alerts @ 15-min | ≈ $1.00 |
| 2 activity-log alerts, action group, budget, saved searches, diag settings | $0 |
| **Phase 2 (opt-in)** — ingestion for 3 VMs + 1 log alert | ≈ $5–12 |

Retention stays at 30 days (the minimum you're not charged for). None of this
changes the fact that the VPN gateway (~$27/mo) and Firewall Basic (~$290/mo
if left on) dominate the bill — which is exactly why the budget alert exists.

---

## 4. Useful queries

All of these are also saved in the workspace under **Queries › Hub-Spoke Lab**.

```kusto
// Is the tunnel up? (latest state per tunnel)
AzureDiagnostics
| where ResourceType == "VIRTUALNETWORKGATEWAYS" and Category == "TunnelDiagnosticLog"
| summarize arg_max(TimeGenerated, status_s, stateChangeReason_s) by Resource, remoteIP_s
```

```kusto
// What did the firewall block in the last hour?
AzureDiagnostics
| where TimeGenerated > ago(1h)
| where ResourceType == "AZUREFIREWALLS" and msg_s has "Deny"
| project TimeGenerated, Category, msg_s
```

```kusto
// Prove storage is only reached through the private endpoint
StorageBlobLogs
| summarize count() by CallerIpAddress, OperationName, StatusText
// expect only 10.2.0.x / 10.1.0.x callers, never a public IP
```

```kusto
// Who changed infrastructure this week, and was it the pipeline?
AzureActivity
| where TimeGenerated > ago(7d) and CategoryValue == "Administrative"
| summarize Ops = count() by Caller, ActivityStatusValue
```

```kusto
// (Phase 2) IPsec negotiation from the on-prem side
Syslog
| where ProcessName has "charon"
| project TimeGenerated, Computer, SyslogMessage
```

---

## 5. Operational notes

- **Log alerts skip query validation on create** (`skip_query_validation = true`).
  The `AzureDiagnostics`/`Heartbeat` tables don't exist in a brand-new
  workspace until the first record lands, and the API rejects rules that
  reference unknown columns. The queries are correct; they just can't be
  proven correct at `apply` time on a fresh workspace.
- **Budget start date** is pinned to the first of the month the budget was
  created and ignored afterwards (`lifecycle.ignore_changes`), otherwise every
  plan would try to move it.
- **Activity Log diagnostic setting is subscription-scoped.** Its name includes
  the environment so `dev` and `prod` can coexist in one subscription. The
  pipeline identity needs `Microsoft.Insights/diagnosticSettings/write` at
  subscription scope — Contributor on the subscription covers this. Set
  `enable_activity_log = false` on the module if the SP is scoped narrower.
- **Everything except `enable_vm_monitoring` is on by default.** If you don't
  want the budget, set `monthly_budget_amount = 0`.

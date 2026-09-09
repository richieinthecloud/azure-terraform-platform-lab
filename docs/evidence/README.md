# Proving the README claims — evidence runbook

The README says this network does six things. This runbook turns each claim
into a **demo step**, a **query**, and an **expected result**, and captures the
output into a timestamped folder here so the claims are backed by data, not
prose.

Two scripts do the work:

| Script | Runs where | Does |
|---|---|---|
| `scripts/generate-demo-traffic.sh` | on `vm-app`, via Bastion SSH | fires one example of every behaviour (east-west ping, allowed + denied egress, private-DNS lookup, PE blob request, on-prem ping) |
| `scripts/capture-evidence.sh` | your workstation (`az`, `terraform`, `jq`) | pulls control-plane state + Log Analytics query results into `docs/evidence/<UTC-timestamp>/*.md` |

---

## The 8-hour demo run

The lab is designed to be spun up, exercised, captured and destroyed. This is
the whole loop.

```bash
# 0. (once) make sure the PR pipeline has planned and applied feature/test,
#    or apply locally:
cd environments/dev
export TF_VAR_vpn_shared_key='<strong-random-string>'
terraform apply                                  # ~35-45 min, the VPN gateway is the slow part

# 1. wait for the tunnel: status should flip to "Connected" within ~5 min of
#    the StrongSwan VM finishing cloud-init
az network vpn-connection show -g rg-hub-dev -n cn-hub-to-onprem-dev --query connectionStatus -o tsv

# 2. collect the values the traffic script needs
terraform output

# 3. SSH to vm-app through Bastion (portal, or az network bastion ssh), then on the VM:
DATA_VM_IP=<data_vm_private_ip> ONPREM_IP=<onprem_server_private_ip> SA=<data_storage_account_name> \
  bash <(curl -fsSL https://raw.githubusercontent.com/richieinthecloud/azure-terraform-platform-lab/feature/test/scripts/generate-demo-traffic.sh)
#    (github.com is on the FQDN allow-list, so this works; or scp the script over)

# 4. give Log Analytics ~10 minutes to ingest, then from your workstation:
cd ../..
./scripts/capture-evidence.sh                    # writes docs/evidence/<timestamp>/

# 5. read the output, commit the folder, destroy
git add docs/evidence && git commit -m "evidence: <date> demo run"
cd environments/dev && terraform destroy         # another ~30-45 min for the gateway
```

Total wall-clock ≈ 2 h of provisioning/destroying plus however long you keep
it up. Budget for the gateway's creation and deletion time — it bills while
it exists, including during the 30–45 min destroy.

---

## Claim → evidence matrix

| # | README claim | Demo step | Where the evidence lives | What "proven" looks like |
|---|---|---|---|---|
| 1 | **East-west inspection** — spoke-to-spoke only via the hub firewall | `ping`/`nc` from `vm-app` (10.1.0.x) to `vm-data` (10.2.0.x) | `01-east-west.md` — `AzureFirewallNetworkRule` log | Rows with `SourceIp 10.1.0.x → DestIp 10.2.0.x, Action: Allow`. If the firewall never saw the flow, the UDR is being bypassed. `00-control-plane.md` also shows the `0.0.0.0/0 → VirtualAppliance` route on both spokes. |
| 2 | **Controlled egress** — FQDN allow-list, everything else denied | `curl` to `security.ubuntu.com` (allowed) and `example.com` + `1.1.1.1` (not allowed) | `02-egress-allowed.md`, `03-egress-denied.md` | Allowed FQDNs show `Action: Allow`; `example.com` shows `Action: Deny` in the application-rule log; the raw-IP request shows a network-rule `Deny`. |
| 3 | **Private-only data access** — storage reached only via the Private Endpoint | `getent hosts <sa>.blob.core.windows.net` then `curl https://<sa>.blob…` from `vm-app` | `04-storage-private.md` — `StorageBlobLogs`; `00-control-plane.md` — `publicNetworkAccess` | DNS resolves to a `10.2.0.64/26` address. `StorageBlobLogs.CallerIpAddress` is a private `10.x` IP, never a public one. `publicNetworkAccess: Disabled` on the account. (HTTP 401/403/404 on the curl is fine — it's the *caller IP* that matters.) |
| 4 | **No public IPs on workload VMs** — admin access via Bastion only | (structural) | `terraform-outputs.json` + `az vm list-ip-addresses` | Output only lists private IPs for `vm-app`/`vm-data`; the NSG's only inbound-22 source is `AzureBastionSubnet`. |
| 5 | **Hybrid connectivity** — on-prem reaches spokes over IPsec with gateway transit | `ping`/`traceroute` from `vm-app` to the on-prem LAN VM (192.168.0.x) | `05-tunnel-state.md`, `06-tunnel-traffic.md`, `00-control-plane.md` (effective routes) | `TunnelDiagnosticLog` latest `status_s == Connected`; `TunnelIngressBytes`/`TunnelEgressBytes` non-zero in the demo window; vm-app's effective route table shows `192.168.0.0/24 → VirtualNetworkGateway` (that's gateway transit) while `0.0.0.0/0 → VirtualAppliance` still points at the firewall (longest-prefix match). |
| 6 | **Observability** — logs, alerts, budget | (structural) | `09-alert-rules.md`, `07-activity.md`, `08-alerts-configured.md` | Alert rules listed as enabled; `AzureActivity` shows the pipeline identity (not a human) performing the writes. |

A run where every row's "proven" column holds is a run you can link to from
the README. A run where one doesn't is a bug — and now you have the log line
to debug it from.

---

## What an 8-hour deployment costs

List prices, **East US, pay-as-you-go, USD, approximate** — check the
[pricing calculator](https://azure.microsoft.com/pricing/calculator/) before
relying on these. Everything below is billed hourly except where noted.

| Resource | Unit price | 8 h | Notes |
|---|---:|---:|---|
| Azure Firewall **Basic** | $0.395 / h | **$3.16** | + $0.065/GB processed (demo traffic ≈ $0). By far the largest line. |
| Azure Bastion **Basic** | $0.19 / h | **$1.52** | Second largest. Only needed while you're SSH-ing. |
| VPN Gateway **Basic** | $0.04 / h | $0.32 | Cheap; slow to create/destroy. |
| 4 × `Standard_B1s` VMs | $0.0104 / h each | $0.33 | app, data, StrongSwan, on-prem LAN |
| 4 × 30 GB Standard HDD OS disks | ≈ $1.54 / mo each | $0.07 | |
| 4 × Standard static public IPs | $0.005 / h each | $0.16 | fw data, fw mgmt, bastion, StrongSwan |
| 1 × Basic dynamic public IP (VPN GW) | $0.004 / h | $0.03 | |
| Private Endpoint | $0.01 / h | $0.08 | + $0.01/GB, ≈ $0 for a demo |
| Private DNS zone | $0.50 / zone / mo | < $0.01 | + $0.40 per million queries |
| Storage account (LRS, near-empty) | per GB / txn | < $0.01 | |
| VNet peering | $0.01 / GB each way | ≈ $0 | demo traffic is KBs |
| Log Analytics ingestion | ≈ $2.30–2.76 / GB | ≈ $0.30–0.60 | Firewall + gateway + storage + Activity Log for 8 h of a mostly-idle lab ≈ 100–250 MB. Activity Log is free. |
| Alert rules (2 metric, 2–3 log, 2 activity-log) | ≈ $1.20 / mo total | < $0.02 | Prorated; activity-log alerts, action group, budget, saved searches are free. |
| **Phase 2 opt-in** — AMA on 3 VMs | ingestion only | ≈ $0.10–0.30 | Syslog + perf at 60 s ≈ 15–40 MB/VM/8 h |
| **Total, 8 h steady state** | | **≈ $6.00 – 6.50** | |
| **+ provisioning & destroy overhead** (~1–1.5 h of gateway/firewall/bastion billing) | | **≈ $0.70 – 1.00** | |
| **Realistic all-in for one demo run** | | **≈ $7 – 8** | |

For contrast, leaving everything running costs ≈ **$17/day** ≈ **$520/month**,
of which Firewall Basic ≈ $290 and Bastion ≈ $140. That is exactly why the
`monthly_budget_amount` alert exists and why the default is 100 — it fires at
$80 actual and at $100 forecast, which is roughly day 5 of a forgotten lab.

Cheapest way to cut the demo bill further: deploy Bastion only when you need
the shell (or replace it with `az network bastion ssh` on a Developer-SKU
Bastion where available), and destroy the firewall between demo days — the
gateway and VMs are a rounding error by comparison.

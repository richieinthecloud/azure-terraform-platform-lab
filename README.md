# Azure Hybrid Hub-and-Spoke — Terraform Platform Lab ☁️🔒

A production-style **hybrid hub-and-spoke network** on Azure, built entirely with
**Terraform** and delivered through a **secretless GitHub Actions CI/CD pipeline**.
The network connects a set of cloud workloads to a **simulated on-premises
datacenter** over an encrypted **Site-to-Site IPsec VPN** — and every component
exists to *prove out* a specific enterprise networking pattern end-to-end.

> **Status:** `dev` environment complete and validated · `prod` scaffolded ·
> Cost-conscious (Basic SKUs, spin-up-for-demo model).

---

## Why this project exists

I wanted hands-on experience with the exact patterns used in real corporate
cloud environments — not just study them for a certification. So rather than a
toy VNet, I built the whole thing the way a platform team would: modular
infrastructure-as-code, environment separation, a PR-gated pipeline that
validates before anything touches Azure, secretless auth, and a real hybrid
connection back to "on-prem." Then I broke it, fixed it, and made sure I
understood *why* each piece is there.

The network is the star. The workloads inside it (a couple of small VMs, one
private-endpoint data service) are intentionally minimal — their only job is to
generate the traffic that demonstrates the behaviours below.

## What it demonstrates

1. **East-west inspection** — a VM in one spoke can only reach a VM in another
   spoke *through the hub Azure Firewall* (forced tunneling via UDR).
2. **Controlled egress** — VMs reach the internet only via an explicit firewall
   **FQDN allow-list**; everything else is denied.
3. **Private-only data access** — the workload reaches its storage account
   *exclusively over a Private Endpoint*, resolved through Private DNS, with the
   public data plane disabled.
4. **No public IPs on workload VMs** — all admin access is via **Azure Bastion**.
5. **Hybrid connectivity** — a host in the simulated on-prem datacenter reaches
   Azure spokes over an **S2S IPsec tunnel**, with spokes routing to on-prem
   through the hub gateway (**gateway transit**).
6. **Observability** — Firewall, Bastion, VPN Gateway, storage and the
   subscription Activity Log stream diagnostics to a **Log Analytics**
   workspace, with **alerts** (firewall health, SNAT, tunnel down, service /
   resource health), a **budget guard-rail** and saved KQL queries. Optional
   guest-level VM telemetry via the Azure Monitor Agent. See
   [`docs/monitoring.md`](docs/monitoring.md) for the coverage audit and plan.

## Architecture

```mermaid
flowchart TB
    subgraph OnPrem["Simulated On-Prem Datacenter (isolated VNet) 192.168.0.0/24"]
        SW["StrongSwan VM (IPsec device)\n+ public IP"]
        OVM["On-prem server VM\n(no public IP)"]
        OVM --- SW
    end

    INET([Internet])

    subgraph Hub["Hub VNet 10.0.0.0/24"]
        VGW["VPN Gateway"]
        FW["Azure Firewall (Basic)\n+ policy rules"]
        BAS["Azure Bastion"]
    end

    subgraph SpokeApp["Spoke: app 10.1.0.0/24"]
        VM1["App VM (no public IP)"]
    end

    subgraph SpokeData["Spoke: data 10.2.0.0/24"]
        VM2["Data VM"]
        PE["Private Endpoint"] --- DATA["Storage (private only)"]
    end

    LOG["Log Analytics\n(Azure Monitor)\n+ alerts · budget · action group"]

    SW <-->|S2S IPsec tunnel| INET <--> VGW
    Hub <-->|peering + gateway transit| SpokeApp
    Hub <-->|peering + gateway transit| SpokeData
    BAS -.->|private SSH| VM1
    BAS -.->|private SSH| VM2
    VM1 -->|east-west via UDR| FW --> VM2
    VM1 -->|private DNS| PE
    FW -.->|diagnostics| LOG
    BAS -.->|diagnostics| LOG
    VGW -.->|tunnel / IKE logs| LOG
    DATA -.->|blob access logs| LOG
    SW -.->|syslog (opt-in AMA)| LOG
```

The on-prem VNet is **not peered** to Azure — its only path is the encrypted
tunnel over the public internet, exactly like a real datacenter.

## IP address plan (IPAM)

Nothing overlaps. On-prem uses `192.168.x` (not `10.x`) so it reads as a
separate site at a glance.

| Network | CIDR | Key subnets |
|---|---|---|
| Hub | `10.0.0.0/24` | `AzureFirewallSubnet` `/26`, `AzureFirewallManagementSubnet` `/26`, `AzureBastionSubnet` `/26`, `GatewaySubnet` `/27` |
| Spoke — app | `10.1.0.0/24` | `snet-workload` `/26` |
| Spoke — data | `10.2.0.0/24` | `snet-workload` `/26`, `snet-privateendpoints` `/26` |
| On-prem (simulated) | `192.168.0.0/24` | `snet-onprem-gateway` `/26` (StrongSwan), `snet-onprem-lan` `/26` |

## How the routing actually works

- **Forced tunneling:** each spoke workload subnet has a route table with
  `0.0.0.0/0 → Azure Firewall private IP`. Because VNet peering is
  non-transitive, this is what forces spoke-to-spoke and internet egress
  *through* the firewall for inspection.
- **Firewall policy:** a rule collection group allows east-west traffic between
  internal ranges (incl. ICMP, so ping-based demos work) and restricts outbound
  HTTP/HTTPS to an approved **FQDN allow-list**. Everything else is denied by
  default.
- **Hybrid routing:** gateway transit propagates the on-prem route
  (`192.168.0.0/24 → VPN gateway`) into the spokes. Longest-prefix match means
  on-prem-bound traffic goes straight to the gateway (symmetric, works), while
  the `/0` default still sends internet/east-west traffic to the firewall.
- **Private DNS:** the `privatelink.blob.core.windows.net` zone is linked to both
  spokes, so the storage account's FQDN resolves to its private endpoint IP.

## Monitoring & alerting

Everything observability-related lives in `modules/monitoring` and is fed by
resource IDs from the environment root. Full audit, gaps and roadmap in
[`docs/monitoring.md`](docs/monitoring.md).

**Collected into Log Analytics (`log-hubspoke-<env>`, 30-day retention)**

| Source | What arrives | Table |
|---|---|---|
| Azure Firewall | network / application rule hits, DNS proxy, all metrics | `AzureDiagnostics` |
| VPN Gateway | gateway, tunnel state, IKE negotiation, route logs + metrics | `AzureDiagnostics` |
| Azure Bastion | metrics only (audit logs need the Standard SKU) | `AzureMetrics` |
| Storage (blob service) | every read/write/delete with caller IP + Transaction/Capacity metrics | `StorageBlobLogs` |
| Subscription Activity Log | all 8 categories — who changed what, service/resource health | `AzureActivity` |
| VMs *(opt-in)* | syslog (`auth`, `daemon` → StrongSwan `charon`, `kern`…), CPU/mem/disk/net, heartbeat | `Syslog`, `Perf`, `Heartbeat` |

**Alerts → action group `ag-platform-<env>`** (email receivers optional)

| Alert | Fires when | Sev |
|---|---|---|
| Firewall health | `FirewallHealth` avg < 100 % over 15 min | 1 |
| S2S tunnel down | latest `TunnelDiagnosticLog` state is `Disconnected` | 1 |
| Firewall SNAT | `SNATPortUtilization` avg > 80 % | 2 |
| VM heartbeat *(opt-in)* | any agent silent > 10 min | 2 |
| Firewall denies | > 50 `Deny` events in 15 min | 3 |
| Service Health / Resource Health | Azure incident, or a resource goes Degraded/Unavailable | — |
| Budget | 80 % actual / 100 % forecast of `monthly_budget_amount` | — |

Nine saved KQL searches are published to the workspace under
**Queries › Hub-Spoke Lab** (denied flows, top egress FQDNs, east-west flows,
tunnel state, IKE events, private-endpoint access, admin operations, and two
VM-level queries).

**Not covered yet:** VNet flow logs, Bastion session audit (SKU), the on-prem
LAN VM (no internet path for an agent), a workbook/dashboard, and the `prod`
environment (empty scaffold).

## Repository structure

```
bootstrap/            # Phase 0: one-time remote-state backend (storage account)
modules/
  hub/                # hub VNet, Firewall (+ policy rules), Bastion, VPN Gateway
  spoke/              # reusable spoke: VNet, NSG, UDR, gateway-transit peering
  onprem/             # simulated datacenter: StrongSwan S2S device + LAN VM
  monitoring/         # Log Analytics + diagnostic settings, alerts, action group, budget, saved queries
environments/
  dev/                # composes hub + 2 spokes + onprem + monitoring + S2S + data
  prod/               # scaffolded (separate state key) — not yet built out
.github/workflows/    # PR checks + apply pipelines (OIDC)
docs/                 # monitoring audit & plan; evidence runbook + captured demo evidence
scripts/              # demo-traffic generator (runs on vm-app) + evidence capture (runs locally)
```

## CI/CD pipeline

Two GitHub Actions workflows separate validation from deployment, so nothing
reaches Azure without first passing checks in an open pull request.

- **PR checks** (`terraform-pr.yml`) — on every PR to `main`: `terraform fmt
  -check`, `init`, `validate`, and `plan`, so a reviewer sees exactly what will
  change. Read-only.
- **Apply** (`terraform-apply.yml`) — on merge to `main`: the full
  `init → validate → plan → apply` against `environments/dev`.

### Secretless auth (OIDC / Workload Identity Federation)

Both workflows authenticate to Azure using **OpenID Connect** federated
credentials — **no client secret is stored in GitHub**. GitHub Actions requests
a short-lived token from GitHub's OIDC provider, which Microsoft Entra ID trusts
via a federated credential scoped to this repo/environment. Nothing to rotate,
nothing to leak.

## Deploying it

**Prerequisites:** an Azure subscription, Terraform ≥ 1.5, and:

- an **SSH key pair** — `ssh-keygen -t ed25519`; put the contents of
  `~/.ssh/id_ed25519.pub` in `ssh_public_key`.
- a **VPN pre-shared key** — a strong random string (set via
  `TF_VAR_vpn_shared_key`, never committed).
- your **admin source IP** (`admin_source_ip`) for on-prem SSH access.

```bash
# 1. One-time: create the remote-state backend
cd bootstrap
terraform init && terraform apply
#   → copy the outputs into environments/dev/backend.tf

# 2. Deploy the dev environment
cd ../environments/dev
cp terraform.tfvars.example terraform.tfvars   # fill in your values
export TF_VAR_vpn_shared_key='<strong-random-string>'
terraform init
terraform validate
terraform plan
terraform apply
```

Secrets live in a git-ignored `terraform.tfvars` (or `TF_VAR_*` env vars) — the
`*.tfvars` pattern is in `.gitignore`.

Monitoring knobs (all optional, see `terraform.tfvars.example`):

| Variable | Default | Effect |
|---|---|---|
| `alert_email_receivers` | `[]` | Who gets alert + budget emails (empty = portal only) |
| `monthly_budget_amount` | `100` | Monthly spend alert at 80 % actual / 100 % forecast (`0` disables) |
| `enable_vm_monitoring` | `false` | Azure Monitor Agent on the VMs: syslog (incl. StrongSwan `charon`), perf, heartbeat alert |

## Cost notes (self-funded lab)

Basic SKUs throughout (Firewall Basic, Bastion Basic, VPN Gateway Basic, `B1s`
VMs). The **VPN Gateway is the expensive, slow piece** (~30–45 min to
deploy/destroy), so the hybrid phase runs on a **spin-up → capture evidence →
`terraform destroy`** model rather than always-on. Cost-awareness in IaC is
itself part of the exercise.

## Design decisions

- **Traditional (peered) hub-spoke**, not Virtual WAN — to keep full control of
  routing/firewall and demonstrate the mechanics a managed hub hides.
- **VPN, not ExpressRoute** — ExpressRoute needs a provider + real circuit and
  can't be labbed cheaply; it's documented as a decision, not built.
- **Simulated on-prem (StrongSwan VNet)** instead of my real home network —
  reproducible by anyone, no CGNAT/dynamic-IP/router dependencies, nothing
  touching a real home LAN.

Monitoring coverage, gaps and the phased plan are in
[`docs/monitoring.md`](docs/monitoring.md).

### Proving the claims

Each of the six behaviours above maps to a demo step, a KQL query and an
expected result in [`docs/evidence/README.md`](docs/evidence/README.md).
`scripts/generate-demo-traffic.sh` (run on `vm-app`) produces the traffic;
`scripts/capture-evidence.sh` (run locally) writes the query output into a
timestamped folder under `docs/evidence/`. The same document has the
per-resource cost table for an 8-hour demo run (≈ $7–8 all-in at list price).

## Challenges & what I learned

- **OIDC federated-credential subject mismatch.** GitHub lowercases the
  environment name in the OIDC subject claim regardless of how it's capitalised
  in repo settings, so a mixed-case federated credential silently never matches
  and login fails with a generic error. Fixed by aligning the subject to the
  lowercased form GitHub actually sends.
- **RBAC is separate from auth.** OIDC handles *authentication*; the service
  principal still needs explicit role assignments at the right scope —
  *authorization* is a deliberate second step.
- **A firewall with no rules is a blackhole.** Once I forced spoke traffic
  through Azure Firewall via UDR, everything dropped — because the policy was
  empty and Firewall is default-deny. Understanding that the UDR and the rule
  collection are *two separate things* was a real "aha."
- **Longest-prefix match decides hybrid routing.** The gateway-propagated
  on-prem `/24` route wins over the `/0` firewall UDR, which is exactly why
  on-prem traffic flows symmetrically instead of hitting an asymmetric-routing
  drop.
- **`fmt` vs `validate` vs deploy** are three different gates. Formatting is
  cosmetic to Terraform but a hard gate in CI; `validate` catches type/reference
  errors; only a real `plan` against the provider catches the rest.
- Debugging all of this taught me to trace a request hop by hop
  (GitHub → OIDC token → Entra ID → RBAC → resource) rather than guess at the
  whole system at once.

## Tech stack

- **Terraform** — infrastructure as code
- **Microsoft Azure** — networking, compute, storage, monitoring
- **GitHub Actions** — CI/CD orchestration
- **Azure OIDC / Workload Identity Federation** — secretless authentication
- **StrongSwan** — IPsec VPN device simulating on-prem

## Roadmap

- Monitoring phase 3/4 (VNet flow logs, workbook, drift alert on non-pipeline
  callers) — see [`docs/monitoring.md`](docs/monitoring.md).
- Build out the `prod` environment (separate state, prod values).
- **BGP** over the S2S tunnel (dynamic routing) — requires VpnGw1+.
- **Point-to-Site** user VPN reusing the hub gateway.
- **Key Vault** for the VPN pre-shared key (read via a data source).
- **Azure Policy** governance (deny public IPs, require tags) and `tfsec`/
  `checkov` in the PR pipeline.

## Changelog

### 2026-09-09 — monitoring build-out (`feature/test`, not yet applied)

- `modules/monitoring` now owns all observability: workspace, diagnostic
  settings, action group, alerts, budget, saved searches, and an opt-in Linux
  Data Collection Rule. The Firewall/Bastion diagnostic settings moved in from
  the dev root with `moved {}` blocks (no destroy/recreate).
- New diagnostics: VPN Gateway, storage blob service, subscription Activity Log.
- New alerts: firewall health, firewall SNAT, firewall deny spike, S2S tunnel
  disconnected, Service Health, Resource Health, VM heartbeat (opt-in).
- New monthly subscription budget (80 % actual / 100 % forecast).
- Nine saved KQL searches under **Hub-Spoke Lab**.
- Opt-in VM guest monitoring (`enable_vm_monitoring`): Azure Monitor Agent on
  `vm-app`, `vm-data` and the StrongSwan VM, plus a firewall network rule to
  the `AzureMonitor` service tag. All three VMs gained a system-assigned
  identity (unconditional; shows as an in-place update on the next plan).
- New root variables: `alert_email_receivers`, `monthly_budget_amount`,
  `enable_vm_monitoring`. New output `action_group_id`.
- Added `environments/dev/terraform.tfvars.example` and `docs/monitoring.md`.
- Added `docs/evidence/README.md` (claim → demo → query → expected-result
  matrix, 8-hour cost estimate) and `scripts/` (demo-traffic generator +
  evidence capture).
- Validated with `terraform fmt` + `validate` (azurerm 4.79.0). Not yet
  planned or applied against Azure — the PR pipeline is the next gate.

#!/usr/bin/env bash
# Run this ON vm-app (via Bastion SSH). It generates one example of every
# behaviour the README claims, so the firewall / storage / DNS logs have
# something to show. Takes ~1 minute. Safe to re-run.
#
#   DATA_VM_IP=10.2.0.4 ONPREM_IP=192.168.0.68 SA=stdatadevabc123 ./generate-demo-traffic.sh
set -u
DATA_VM_IP="${DATA_VM_IP:?set DATA_VM_IP (terraform output data_vm_private_ip)}"
ONPREM_IP="${ONPREM_IP:?set ONPREM_IP (terraform output onprem_server_private_ip)}"
SA="${SA:?set SA (terraform output data_storage_account_name)}"

say() { printf '\n=== %s ===\n' "$*"; }

say "1. East-west: app spoke -> data spoke (must transit the hub firewall)"
ping -c 3 -W 2 "$DATA_VM_IP" || true
nc -zv -w 3 "$DATA_VM_IP" 22 || true

say "2a. Egress ALLOWED: FQDN on the allow-list"
curl -sS -o /dev/null -w 'security.ubuntu.com -> HTTP %{http_code}\n' --max-time 10 http://security.ubuntu.com/ || true
curl -sS -o /dev/null -w 'github.com -> HTTP %{http_code}\n'          --max-time 10 https://github.com/ || true

say "2b. Egress DENIED: FQDN not on the allow-list (expect timeout / firewall block)"
curl -sS -o /dev/null -w 'example.com -> HTTP %{http_code}\n' --max-time 8 https://example.com/ || echo "example.com -> blocked (as intended)"
curl -sS -o /dev/null -w '1.1.1.1:443 -> HTTP %{http_code}\n' --max-time 8 https://1.1.1.1/ || echo "1.1.1.1 -> blocked (as intended)"

say "3. Private DNS: storage FQDN must resolve to a 10.2.0.64/26 address"
FQDN="${SA}.blob.core.windows.net"
getent hosts "$FQDN" || nslookup "$FQDN" || true

say "3b. Private-endpoint data plane: request hits the PE (401/403/404 are all fine - it's the CallerIpAddress in StorageBlobLogs we want)"
curl -sS -o /dev/null -w "${FQDN} -> HTTP %{http_code}\n" --max-time 10 "https://${FQDN}/?comp=list" || true

say "4. Hybrid: on-prem host over the S2S tunnel (gateway transit)"
ping -c 3 -W 3 "$ONPREM_IP" || true
traceroute -n -m 8 -w 2 "$ONPREM_IP" 2>/dev/null || tracepath -n "$ONPREM_IP" || true

say "done - wait ~5-10 min for logs to land, then run scripts/capture-evidence.sh from your workstation"

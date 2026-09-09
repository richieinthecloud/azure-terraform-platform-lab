#!/usr/bin/env bash
# Pull the evidence for every README claim out of Log Analytics and the ARM
# control plane, and write it as Markdown under docs/evidence/<UTC timestamp>/.
#
# Run from your workstation (needs: az cli logged in, terraform, jq) after
# scripts/generate-demo-traffic.sh has been run on vm-app and ~10 min have
# passed for logs to land.
#
#   ./scripts/capture-evidence.sh                # uses environments/dev
#   ENV_DIR=environments/prod ./scripts/capture-evidence.sh
set -euo pipefail

ENV_DIR="${ENV_DIR:-environments/dev}"
ENV_NAME="$(basename "$ENV_DIR")"
STAMP="$(date -u +%Y-%m-%dT%H%MZ)"
OUT="docs/evidence/${STAMP}"
mkdir -p "$OUT"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need az; need terraform; need jq

echo "-> terraform outputs"
TF_OUT="$(terraform -chdir="$ENV_DIR" output -json)"
echo "$TF_OUT" | jq 'with_entries(.value |= .value)' > "$OUT/terraform-outputs.json"

WS_NAME="$(echo "$TF_OUT" | jq -r '.log_analytics_workspace_name.value')"
RG_MON="rg-monitoring-${ENV_NAME}"
RG_HUB="rg-hub-${ENV_NAME}"
WS_ID="$(az monitor log-analytics workspace show -g "$RG_MON" -n "$WS_NAME" --query customerId -o tsv)"

echo "-> control-plane state"
{
  echo "# Control-plane state (${STAMP})"
  echo
  echo '## S2S connection'
  echo '```'
  az network vpn-connection show -g "$RG_HUB" -n "cn-hub-to-onprem-${ENV_NAME}" \
    --query '{name:name,status:connectionStatus,ingressBytes:ingressBytesTransferred,egressBytes:egressBytesTransferred}' -o yaml
  echo '```'
  echo
  echo '## Firewall'
  echo '```'
  az network firewall show -g "$RG_HUB" -n "afw-hub-${ENV_NAME}" \
    --query '{name:name,sku:sku.tier,state:provisioningState,privateIp:ipConfigurations[0].privateIPAddress}' -o yaml
  echo '```'
  echo
  echo '## Spoke route tables (the forced tunnel)'
  echo '```'
  for s in app data; do
    az network route-table route list -g "rg-spoke-${s}-${ENV_NAME}" --route-table-name "rt-spoke-${s}-${ENV_NAME}" \
      --query '[].{route:name,prefix:addressPrefix,nextHop:nextHopType,ip:nextHopIpAddress}' -o table
  done
  echo '```'
  echo
  echo '## Effective routes on vm-app NIC (gateway-transit route should appear as VirtualNetworkGateway)'
  echo '```'
  az network nic show-effective-route-table -g "rg-spoke-app-${ENV_NAME}" -n "nic-app-${ENV_NAME}" \
    --query '[].{source:source,prefix:addressPrefix[0],nextHop:nextHopType,ip:nextHopIpAddress[0]}' -o table
  echo '```'
  echo
  echo '## Storage public access'
  echo '```'
  az storage account show -n "$(echo "$TF_OUT" | jq -r '.data_storage_account_name.value')" \
    --query '{publicNetworkAccess:publicNetworkAccess,privateEndpoints:privateEndpointConnections[].privateEndpoint.id}' -o yaml
  echo '```'
} > "$OUT/00-control-plane.md"

# name|title|claim|query
QUERIES=$(cat <<'Q'
01-east-west|East-west inspection|Spoke-to-spoke traffic transits the hub firewall|AzureDiagnostics | where TimeGenerated > ago(2h) | where ResourceType == "AZUREFIREWALLS" and Category == "AzureFirewallNetworkRule" | parse msg_s with Protocol " request from " SourceIp ":" SourcePort " to " DestIp ":" DestPort ". Action: " Action "." * | where SourceIp startswith "10.1." and DestIp startswith "10.2." | summarize Flows=count() by Protocol, SourceIp, DestIp, DestPort, Action
02-egress-allowed|Controlled egress (allowed)|Only allow-listed FQDNs get out|AzureDiagnostics | where TimeGenerated > ago(2h) | where ResourceType == "AZUREFIREWALLS" and Category == "AzureFirewallApplicationRule" | parse msg_s with Protocol " request from " SourceIp ":" SourcePort " to " Fqdn ":" DestPort ". Action: " Action "." * | summarize Hits=count() by Fqdn, Action | order by Action, Hits desc
03-egress-denied|Controlled egress (denied)|Everything else is denied|AzureDiagnostics | where TimeGenerated > ago(2h) | where ResourceType == "AZUREFIREWALLS" | where msg_s has "Deny" | project TimeGenerated, Category, msg_s | order by TimeGenerated desc | take 20
04-storage-private|Private-only data access|Blob requests arrive from private IPs only|StorageBlobLogs | where TimeGenerated > ago(2h) | summarize Requests=count() by CallerIpAddress, OperationName, StatusCode, AuthenticationType | order by Requests desc
05-tunnel-state|Hybrid connectivity|S2S tunnel is Connected|AzureDiagnostics | where TimeGenerated > ago(7d) | where ResourceType == "VIRTUALNETWORKGATEWAYS" and Category == "TunnelDiagnosticLog" | project TimeGenerated, instance_s, remoteIP_s, status_s, stateChangeReason_s | order by TimeGenerated desc | take 20
06-tunnel-traffic|Hybrid connectivity (traffic)|Bytes actually crossed the tunnel|AzureMetrics | where TimeGenerated > ago(2h) | where ResourceProvider == "MICROSOFT.NETWORK" and MetricName in ("TunnelIngressBytes", "TunnelEgressBytes") | summarize Bytes=sum(Total) by MetricName, bin(TimeGenerated, 15m) | order by TimeGenerated desc
07-activity|Change audit|Who applied what|AzureActivity | where TimeGenerated > ago(24h) | where CategoryValue == "Administrative" and ActivityStatusValue == "Success" | summarize Ops=count() by Caller, OperationNameValue | order by Ops desc | take 30
08-alerts-configured|Alerting exists|Alert rules are deployed|AzureActivity | where TimeGenerated > ago(7d) | where ResourceProviderValue == "MICROSOFT.INSIGHTS" and OperationNameValue has "write" | summarize by _ResourceId | order by _ResourceId asc
Q
)

echo "-> Log Analytics queries"
while IFS='|' read -r name title claim query; do
  [ -z "$name" ] && continue
  echo "   $name"
  {
    echo "# ${title}"
    echo
    echo "**Claim:** ${claim}"
    echo
    echo '```kusto'
    echo "$query"
    echo '```'
    echo
    echo "Captured ${STAMP} from workspace \`${WS_NAME}\`."
    echo
    echo '```'
    az monitor log-analytics query -w "$WS_ID" --analytics-query "$query" -o table 2>&1 || echo "(query failed - table may not exist yet)"
    echo '```'
  } > "$OUT/${name}.md"
done <<< "$QUERIES"

echo "-> alert rules"
{
  echo "# Alert rules and action group (${STAMP})"
  echo
  echo '```'
  az monitor metrics alert list -g "$RG_MON" --query '[].{name:name,severity:severity,enabled:enabled}' -o table
  az monitor scheduled-query list -g "$RG_MON" --query '[].{name:name,severity:severity,enabled:enabled}' -o table
  az monitor activity-log alert list -g "$RG_MON" --query '[].{name:name,enabled:enabled}' -o table
  az monitor action-group list -g "$RG_MON" --query '[].{name:name,emails:emailReceivers[].emailAddress}' -o yaml
  echo '```'
} > "$OUT/09-alert-rules.md"

echo "-> index"
{
  echo "# Evidence capture ${STAMP} (${ENV_NAME})"
  echo
  for f in "$OUT"/*.md; do
    b="$(basename "$f")"; [ "$b" = "README.md" ] && continue
    echo "- [${b%.md}](./${b})"
  done
} > "$OUT/README.md"

echo "wrote $OUT"

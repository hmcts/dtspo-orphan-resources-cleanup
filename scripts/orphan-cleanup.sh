#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: bash $0 [-m dry-run]" >&2
  echo "Preview only. Live deletion is disabled. JSON is written to stdout." >&2
}

while getopts ":m:" opt; do
  case "$opt" in
    m)
      if [[ "$OPTARG" != dry-run ]]; then
        echo "Unsupported mode: $OPTARG. Live deletion is disabled." >&2
        exit 1
      fi
      ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
if [[ $# -ne 0 ]]; then
  usage
  exit 1
fi

for dependency in az jq; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Required command not found: $dependency" >&2
    exit 1
  fi
done

role_def_name_match="Orphan Resource Cleanup Read/Delete"
role_principal_id_match="50cce126-c44a-48bb-9361-5f55868d3182"

# These queries identify review candidates, not resources approved for deletion.
orphan_queries=(
  'Load Balancers:resources | where type =~ "microsoft.network/loadbalancers" | where properties.backendAddressPools == "[]"'
  'App Service Plans:resources | where type =~ "microsoft.web/serverfarms" | where properties.numberOfSites == 0'
  'Route Tables:resources | where type =~ "microsoft.network/routetables" | where isnull(properties.subnets)'
  'Availability Sets:resources | where type =~ "microsoft.compute/availabilitysets" | where properties.virtualMachines == "[]"'
  'Network Security Groups:resources | where type =~ "microsoft.network/networksecuritygroups" | where isnull(properties.networkInterfaces) and isnull(properties.subnets)'
  'Resource Groups:ResourceContainers | where type =~ "microsoft.resources/subscriptions/resourcegroups" | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | join kind=leftouter (Resources | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | summarize count() by rgAndSub) on rgAndSub | where isnull(count_)'
  'Public IPs:resources | where type =~ "microsoft.network/publicipaddresses" | where isnull(properties.ipAddress) or properties.ipAddress == ""'
  'Network Interfaces:resources | where type =~ "microsoft.network/networkinterfaces" | where isnull(properties.privateEndpoint) | where isnull(properties.privateLinkService) | where properties !has "virtualmachine"'
  'Disks:resources | where type =~ "microsoft.compute/disks" | where managedBy == "" | where properties.diskState =~ "Unattached" | where not(name endswith "-ASRReplica" or name startswith "ms-asr-") | where not(name startswith "pvc-" and resourceGroup endswith "-aks-node-rg")'
)

workDir=$(mktemp -d)
trap 'rm -f "$workDir/accounts.json" "$workDir/roles.json" "$workDir/page.json" "$workDir/rows.jsonl" "$workDir/subscriptions.json"; rmdir "$workDir"' EXIT

az account list --output json --only-show-errors > "$workDir/accounts.json"
if ! jq -e 'type == "array" and all(.[]; (.id | type) == "string")' "$workDir/accounts.json" >/dev/null; then
  echo "Azure returned an invalid subscription list; preview stopped." >&2
  exit 1
fi
subscriptions=()
while IFS= read -r subscription; do
  echo "Checking cleanup role assignment in subscription $subscription..." >&2
  az role assignment list --subscription "$subscription" --all --output json --only-show-errors > "$workDir/roles.json"
  if ! jq -e 'type == "array"' "$workDir/roles.json" >/dev/null; then
    echo "Azure returned an invalid role-assignment list for $subscription; preview stopped." >&2
    exit 1
  fi
  # Inherited assignments can have a null roleDefinitionName (unresolvable role); they never match.
  # The role must cover the whole subscription: assigned at the subscription or an ancestor management group.
  if jq -e --arg role "$role_def_name_match" --arg principal "$role_principal_id_match" \
    --arg scope "/subscriptions/$subscription" '
      any(.[]; .roleDefinitionName == $role and .principalId == $principal and
        (.scope | type) == "string" and
        ((.scope | ascii_downcase) == ($scope | ascii_downcase) or
         (.scope | ascii_downcase | startswith("/providers/microsoft.management/managementgroups/"))))
    ' "$workDir/roles.json" >/dev/null; then
    subscriptions+=("$subscription")
  fi
done < <(jq -r '.[].id' "$workDir/accounts.json")

if [[ ${#subscriptions[@]} -eq 0 ]]; then
  echo "No subscriptions have the cleanup role at subscription or management-group level. Refusing an unscoped query." >&2
  exit 1
fi
printf '%s\n' "${subscriptions[@]}" | jq -R . | jq -s . > "$workDir/subscriptions.json"
: > "$workDir/rows.jsonl"

for query_item in "${orphan_queries[@]}"; do
  query_name="${query_item%%:*}"
  query="${query_item#*:} | project id, name, type, resourceGroup, subscriptionId, tags"
  echo "Querying review candidates: $query_name..." >&2
  skip_token=
  seen_tokens=()
  record_count=0
  while :; do
    args=(graph query -q "$query" --subscriptions "${subscriptions[@]}" --first 1000 --output json --only-show-errors)
    if [[ -n "$skip_token" ]]; then
      args+=(--skip-token "$skip_token")
    fi
    az "${args[@]}" > "$workDir/page.json"
    if ! jq -e --slurpfile subscriptions "$workDir/subscriptions.json" '
      type == "object" and (.data | type) == "array" and
      all(.data[]; . as $row |
        (.id | type) == "string" and (.subscriptionId | type) == "string" and
        (.subscriptionId as $sub | $subscriptions[0] | index($sub)) != null and
        ((.id | ascii_downcase) | startswith("/subscriptions/" + ($row.subscriptionId | ascii_downcase) + "/")))
    ' "$workDir/page.json" >/dev/null; then
      echo "Invalid or out-of-scope Resource Graph results for $query_name; preview stopped." >&2
      exit 1
    fi
    jq -c --arg category "$query_name" '.data[] | . + {category: $category}' \
      "$workDir/page.json" >> "$workDir/rows.jsonl"
    next_token=$(jq -r '.skip_token // empty' "$workDir/page.json")
    record_count=$((record_count + $(jq '.data | length' "$workDir/page.json")))
    if [[ -z "$next_token" ]]; then
      total_records=$(jq -r '.total_records // 0' "$workDir/page.json")
      if [[ "$total_records" -gt "$record_count" ]]; then
        echo "Resource Graph omitted a pagination token for $query_name; preview is incomplete." >&2
        exit 1
      fi
      break
    fi
    for seen_token in "${seen_tokens[@]+"${seen_tokens[@]}"}"; do
      if [[ "$next_token" == "$seen_token" ]]; then
        echo "Resource Graph repeated a pagination token for $query_name; preview is incomplete." >&2
        exit 1
      fi
    done
    seen_tokens+=("$next_token")
    skip_token=$next_token
  done
done

jq -s --arg checkedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --slurpfile subscriptions "$workDir/subscriptions.json" '
  map(. + {
    ignored: ((.tags // {} | to_entries) |
      any(.[]; (.key | ascii_downcase) == "ignoredbyorphancleanup" and
        (.value | tostring | ascii_downcase) == "true"))
  }) |
  unique_by(.id | ascii_downcase) |
  {
    mode: "preview",
    checkedAt: $checkedAt,
    warning: "Review candidates only; existence and query matches do not establish that deletion is safe.",
    subscriptions: $subscriptions[0],
    summary: {
      candidates: (map(select(.ignored | not)) | length),
      ignored: (map(select(.ignored)) | length)
    },
    candidates: map(select(.ignored | not)),
    ignored: map(select(.ignored))
  }
' "$workDir/rows.jsonl"

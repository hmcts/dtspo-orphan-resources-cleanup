# Orphan Resources queries obtained from Orphan Resources Workbook
# available at https://portal.azure.com/#@HMCTS.NET/resource/subscriptions/bf308a5c-0624-4334-8ff8-8dca9fd43783/resourceGroups/platopsmonitor_test/providers/microsoft.insights/workbooks/03553b7d-6be1-459a-b747-7c69e21f5cb3/workbook
WEBHOOK_URL=$1
SLACK_CHANNEL_NAME=$2


# Function to send slack message when a resource fails to delete
send_slack_message () {
  curl -s -X POST --data-urlencode "payload={\"channel\": \"${SLACK_CHANNEL_NAME}\", \"username\": \"Plato\", \"text\": \"$1\", \"icon_emoji\": \":plato:\"}" $WEBHOOK_URL
}
# Install resource-graph
echo "Installing resource-graph extension"
az config set extension.use_dynamic_install=yes_prompt
az extension add --name resource-graph

resources_to_delete=()
orphan_queries=(
    # Load Balancers
    'resources | where type == "microsoft.network/loadbalancers" | where properties.backendAddressPools == "[]" '
    # App Service Plans
    'resources | where type =~ "microsoft.web/serverfarms" | where properties.numberOfSites == 0'
    # Route Tables
    'resources | where type == "microsoft.network/routetables" | where isnull(properties.subnets)'
    # Availability Sets
    'resources | where type =~ "Microsoft.Compute/availabilitySets" | where properties.virtualMachines == "[]"'
    # NSGs
    'resources | where type == "microsoft.network/networksecuritygroups" and isnull(properties.networkInterfaces) and isnull(properties.subnets)'
    # Resource Groups
    'ResourceContainers | where type == "microsoft.resources/subscriptions/resourcegroups" | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | join kind=leftouter (Resources | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | summarize count() by rgAndSub) on rgAndSub | where isnull(count_)'
    # Public IPs
    'resources | where type == "microsoft.network/publicipaddresses" | where properties.ipConfiguration == ""'
    #  Network Interfaces
    'resources | where type has "microsoft.network/networkinterfaces" | where isnull(properties.privateEndpoint) | where isnull(properties.privateLinkService) | where properties !has "virtualmachine"'
    # Disks
    'resources | where type has "microsoft.compute/disks" | extend diskState = tostring(properties.diskState) | where managedBy == "" | where not(name endswith "-ASRReplica" or name startswith "ms-asr-")'
)

# Graph query to fetch orphaned Resource IDs 
for query in "${orphan_queries[@]}"
do
  resources_to_delete+=$(az graph query -q "$query" | jq '.data[].id')
done

# Solves problem of some resource ID's not having space between them in jq output
resources_to_delete=$(sed 's/""/" "/g' <<< $resources_to_delete)

# Convert into array to loop over resources and sequentially (to record failures) delete them
resources_to_delete=($resources_to_delete)
for resource in "${resources_to_delete[@]:0:1}"
do
  # Trim " from resource, as az command also wraps with '
  resource=$(echo $resource | tr -d '"')
  echo "Attemping delete of: $resource\n"
  # Check if resource should be ignored by this automation, based on tag ignoredByOrphanCleanup: true
#   ignoreResource=$(az resource show --ids $resource | jq '.tags.ignoredByOrphanCleanup')
#   if [[ "$ignoreResource" =~ "true" ]] ; then
#     echo "Skipping $resource as it is tagged."
#   else
#     if az resource delete --ids $resource ; then
#       echo "Successfully deleted!"
#     else
#       send_slack_message "A resource failed to delete!\nTo see why, you can run: az resource delete --ids $resource --verbose\n"
#       echo "Deletion failed, to see why this occured please run: az resource delete --ids $resource --verbose"
#     fi
#   fi
done
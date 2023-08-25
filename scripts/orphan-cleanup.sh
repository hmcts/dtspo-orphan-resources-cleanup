# Orphan Resources queries obtained from Orphan Resources Workbook
# available at https://portal.azure.com/#@HMCTS.NET/resource/subscriptions/bf308a5c-0624-4334-8ff8-8dca9fd43783/resourceGroups/platopsmonitor_test/providers/microsoft.insights/workbooks/03553b7d-6be1-459a-b747-7c69e21f5cb3/workbook
WEBHOOK_URL=$1
SLACK_CHANNEL_NAME=$2
RUN_OPTION=""

role_def_name_match="Orphan Resource Cleanup Read/Delete"
role_principal_match="DTS Bootstrap (sub:dcd-cft-sandbox)"
role_principal_match_id="d45edc3f-b3b7-49d2-8228-be93b557b583"

# Mode option to run in dry run (default for pr build, give -m dry-run locally
while getopts ":m:" opt; do
  case $opt in
    m)
      echo "-m (mode) option was triggered with parameter: $OPTARG" >&2
      RUN_OPTION=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

# Function to send slack message when a resource fails to delete
function send_slack_message () {
  echo "Deletion failed, to see why this occured please run: az resource delete --ids $resource --verbose"
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
    'ResourceContainers | where type == "microsoft.resources/subscriptions/resourcegroups" | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | join kind=leftouter (Resources | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | summarize count() by rgAndSub) on rgAndSub | where isnull(count_) | extend Details = pack_all() | project subscriptionId, Resource=id, count_, location, tags ,Details'
    # Public IPs
    'resources | where type == "microsoft.network/publicipaddresses" | where properties.ipConfiguration == ""'
    #  Network Interfaces
    'resources | where type has "microsoft.network/networkinterfaces" | where isnull(properties.privateEndpoint) | where isnull(properties.privateLinkService) | where properties !has "virtualmachine"'
    # Disks
    'resources | where type has "microsoft.compute/disks" | extend diskState = tostring(properties.diskState) | where managedBy == "" | where not(name endswith "-ASRReplica" or name startswith "ms-asr-")'
)

# Fetch subscriptions to run commands against
subs=($(az account list | jq '.[].id' | tr -d '\n' | sed 's/""/ /g' | tr -d '"'))

# iterate subs, check for required role assignment, form concat'd string for future azcli commands
subs_with_match=()
for sub in "${subs[@]}"; do
  # get assignments and create array of ids
  echo checking $sub for required role assignment...
  sub_role_assignments=$(az role assignment list --subscription $sub --output json)
  sub_role_ids=($(echo $sub_role_assignments | jq -r '.[].name'))

  # iterate id array and get json def block for each role assignment
  for sub_role_id in $(echo "${sub_role_ids[@]}"); do
    role_block=$(echo $sub_role_assignments | jq --arg sub_role_idjq "$sub_role_id" '.[] | select(.name==$sub_role_idjq)')

    # grab roleDefinitonName & principalName for use in conditional evaluation
    sub_role_def_name=$(echo $role_block | jq '.roleDefinitionName' | tr -d '"')
    sub_role_principal_name=$(echo $role_block | jq '.principalName' | tr -d '"')

    # Add sub to array if it has required role assignment and service principal
    if [ "$sub_role_def_name" = "$role_def_name_match" ] && [[ "$sub_role_principal_name" = "$role_principal_match" || "$sub_role_principal_name" = "$role_principal_match_id" ]]; then
      subs_with_match+=($sub)
      break
    fi
  done
done
subs_to_cleanup=${subs_with_match[@]}


echo "Subscriptions to run against: $subs_to_cleanup"

# Graph query to fetch orphaned Resource IDs 
for query in "${orphan_queries[@]}"
do
  resources_to_delete+=$(az graph query -q "$query" --subscriptions $subs_to_cleanup | jq '.data[].id')
done

# Solves problem of some resource ID's not having space between them in jq output
resources_to_delete=$(sed 's/""/" "/g' <<< $resources_to_delete)

# Convert into array to loop over resources and sequentially (to record failures) delete them
resources_to_delete=($resources_to_delete)
for resource in "${resources_to_delete[@]}"
do
  # Trim " from resource, as az command also wraps with '
  resource=$(echo $resource | tr -d '"')
  if [[ "$RUN_OPTION" =~ "dry-run" ]] ; then
    echo "Dry-Run delete of: $resource\n"
  else
   echo "Attemping delete of: $resource\n"
    # # Check if resource should be ignored by this automation, based on tag ignoredByOrphanCleanup: true
    # ignoreResource=$(az resource show --ids $resource | jq '.tags.ignoredByOrphanCleanup')
    # if [[ "$ignoreResource" =~ "true" ]] ; then
    #   echo "Skipping $resource as it is tagged."
    # else
    #   if az resource delete --ids $resource ; then
    #     echo "Successfully deleted!"
    #   else
    #     send_slack_message "A resource failed to delete!\nTo see why, you can run: az resource delete --ids $resource --verbose\n"
    #   fi
    # fi
  fi
done
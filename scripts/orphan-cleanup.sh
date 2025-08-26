#!/usr/bin/env bash
# Orphan Resources queries obtained from Orphan Resources Workbook
# available at https://portal.azure.com/#@HMCTS.NET/resource/subscriptions/bf308a5c-0624-4334-8ff8-8dca9fd43783/resourceGroups/platopsmonitor_test/providers/microsoft.insights/workbooks/03553b7d-6be1-459a-b747-7c69e21f5cb3/workbook
RUN_OPTION=""

role_def_name_match="Orphan Resource Cleanup Read/Delete"
role_principal_id_match="50cce126-c44a-48bb-9361-5f55868d3182"

PVC_RETENTION_DAYS=${PVC_RETENTION_DAYS:-3}

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

# Install resource-graph
echo "Installing resource-graph extension"
az config set extension.use_dynamic_install=yes_prompt
az extension add --name resource-graph

resources_to_delete=()
orphan_queries=(
    # Load Balancers
    'Load Balancers:resources | where type == "microsoft.network/loadbalancers" | where properties.backendAddressPools == "[]" '
    # App Service Plans
    'App Service Plans:resources | where type =~ "microsoft.web/serverfarms" | where properties.numberOfSites == 0'
    # Route Tables
    'Route Tables:resources | where type == "microsoft.network/routetables" | where isnull(properties.subnets)'
    # Availability Sets
    'Availability Sets:resources | where type =~ "Microsoft.Compute/availabilitySets" | where properties.virtualMachines == "[]"'
    # NSGs
    'Network Security Groups:resources | where type == "microsoft.network/networksecuritygroups" and isnull(properties.networkInterfaces) and isnull(properties.subnets)'
    # Resource Groups
    'Resource Groups:ResourceContainers | where type == "microsoft.resources/subscriptions/resourcegroups" | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | join kind=leftouter (Resources | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | summarize count() by rgAndSub) on rgAndSub | where isnull(count_)'
    # Public IPs
    'Public IPs:resources | where type == "microsoft.network/publicipaddresses" | where isnull(properties.ipAddress) or properties.ipAddress == ""'
    #  Network Interfaces
    'Network Interfaces:resources | where type has "microsoft.network/networkinterfaces" | where isnull(properties.privateEndpoint) | where isnull(properties.privateLinkService) | where properties !has "virtualmachine"'
    # Disks
    "Disks:resources | where type has 'microsoft.compute/disks' | extend diskState = tostring(properties.diskState), createdOn = todatetime(properties.timeCreated) | where isnull(managedBy) or managedBy == '' | where diskState ==~ 'Unattached' | where not(name endswith '-ASRReplica' or name startswith 'ms-asr-') | where createdOn < ago(${PVC_RETENTION_DAYS}d)"
)

# Fetch subscriptions to run commands against
subs=($(az account list | jq '.[].id' | tr -d '\n' | sed 's/""/ /g' | tr -d '"'))

# iterate subs, check for required role assignment, form concat'd string for future azcli commands
subs_with_match=()
subs_names_with_match=()
for sub in "${subs[@]}"; do
  # get the name
  name=$(az account show --subscription $sub | jq '.name')
  # get assignments and create array of ids
  echo checking $name for required role assignment...
  sub_role_assignments=$(az role assignment list --subscription $sub --all --output json)
  sub_role_ids=($(echo $sub_role_assignments | jq -r '.[].name'))

  # iterate id array and get json def block for each role assignment
  for sub_role_id in $(echo "${sub_role_ids[@]}"); do
    role_block=$(echo $sub_role_assignments | jq --arg sub_role_idjq "$sub_role_id" '.[] | select(.name==$sub_role_idjq)')

    # grab roleDefinitonName & principalName for use in conditional evaluation
    sub_role_def_name=$(echo $role_block | jq '.roleDefinitionName' | tr -d '"')
    sub_role_principal_id=$(echo $role_block | jq '.principalId' | tr -d '"')

    # Add sub to array if it has required role assignment and service principal
    if [ "$sub_role_def_name" = "$role_def_name_match" ] && [ "$sub_role_principal_id" = "$role_principal_id_match" ]; then
      echo "role assignment matched."
      subs_with_match+=($sub)
      sub_names_with_match+=($name)
      break
    fi
  done
done
subs_to_cleanup=${subs_with_match[@]}
sub_names_to_cleanup=${sub_names_with_match[@]}


echo "Subscriptions to run against: $sub_names_to_cleanup"

# Graph query to fetch orphaned Resource IDs
for query_item in "${orphan_queries[@]}"
do
  query_name="${query_item%%:*}"
  query="${query_item##*:}"
  echo "checking for orphaned $query_name..."
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
    message=$(echo "Dry-Run delete of: $resource\n")
    echo "$message"
    jq -n --arg output "$message" '{message: $output}' >> failedDeletes.json
  else
    echo "Attemping delete of: $resource\n"
    # Check if resource should be ignored by this automation, based on tag ignoredByOrphanCleanup: true
    ignoreResource=$(az resource show --ids $resource | jq '.tags.ignoredByOrphanCleanup')
    if [[ "$ignoreResource" =~ "true" ]] ; then
      echo "Skipping $resource as it is tagged."
    else
      if az resource delete --ids $resource ; then
        echo "Successfully deleted!"
      else
        message=$(echo "A resource failed to delete!\nTo see why, you can run: az resource delete --ids $resource --verbose\n")
        echo "$message"
        jq -n --arg output "$message" '{message: $output}' >> failedDeletes.json
      fi
    fi
  fi
done

#Clear down any existing file contents in final file
true > status/deletionStatus.json

if [ -f failedDeletes.json ]; then
  failedDeleteCount=$(jq -s '. | length' failedDeletes.json)
else
  failedDeleteCount=0
fi

# If there are more than 0 objects, print the object values into an array
if [ "$failedDeleteCount" -gt 0 ]; then
  # Convert failedDeletes.json to valid json file and save
  jq -s '.' failedDeletes.json > status/deletionStatus.json
  rm failedDeletes.json
else
  echo "All resources deleted successfully"
  echo "[]" > status/deletionStatus.json
fi


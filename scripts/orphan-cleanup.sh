# Orphan Resources queries obtained from Orphan Resources Workbook
# available at https://portal.azure.com/#@HMCTS.NET/resource/subscriptions/bf308a5c-0624-4334-8ff8-8dca9fd43783/resourceGroups/platopsmonitor_test/providers/microsoft.insights/workbooks/03553b7d-6be1-459a-b747-7c69e21f5cb3/workbook
WEBHOOK_URL=$1
SLACK_CHANNEL_NAME=$2
RUN_OPTION=""

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
    # Resource Groups
    'ResourceContainers | where type == "microsoft.resources/subscriptions/resourcegroups" | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | join kind=leftouter (Resources | extend rgAndSub = strcat(resourceGroup, "--", subscriptionId) | summarize count() by rgAndSub) on rgAndSub | where isnull(count_) | extend Details = pack_all() | project subscriptionId, Resource=id, count_, location, tags , Details'
)

# Fetch subscriptions to run commands against
subs=$(0978315c-75fe-4ada-9d11-1eb5e0e0b214)
echo "Subscriptions to run against: $subs"

# Graph query to fetch orphaned Resource IDs 
for query in "${orphan_queries[@]}"
do
  az graph query -q "$query" --subscriptions $subs
done
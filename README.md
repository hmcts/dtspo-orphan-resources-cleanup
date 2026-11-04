# dtspo-orphan-resources-cleanup

Azure orphan-resource investigation using GitHub Actions and Azure Resource Graph.

## Safety status: manual preview only

Live deletion is disabled in both the workflow and script. There is no schedule,
live job, deletion command, or status-file commit step. Re-enabling a workflow in
GitHub will not restore automatic deletion with this version.

Run `orphaned-resource-cleanup` manually and download the
`orphan-resource-preview` artifact. Checkout uses the built-in `GITHUB_TOKEN`
with `contents: read`, not `PLATFORM_USER_TOKEN`. The existing Azure OIDC
identity is unchanged; its existing permissions are not reduced by this change.
OIDC federation must allow the branch used for the workflow.

For a local preview, sign in to Azure CLI and install the Resource Graph extension
if missing:

```bash
az extension add --name resource-graph
bash scripts/orphan-cleanup.sh -m dry-run > /tmp/orphan-resource-preview.json
jq '.summary, .candidates, .ignored' /tmp/orphan-resource-preview.json
```

No mode argument also produces a preview. Any mode other than `dry-run` is
rejected before Azure is called. The script only reads Azure data and writes
its JSON report to stdout. It never changes `status/deletionStatus.json`,
which remains the historical failure list used by daily monitoring.

## Scope and interpretation

Only subscriptions where the existing cleanup principal has the `Orphan
Resource Cleanup Read/Delete` role at subscription or management-group level
(the role is currently assigned at management-group level) are queried.
Resource-group-level assignments do not count. Inherited assignments whose role
name cannot be resolved are ignored. No matching subscriptions, role-discovery
failures, and query failures stop the preview with a non-zero exit; they never
produce an empty success report.
Resource Graph pagination is followed so the preview is not limited to the
first page.

Resource groups themselves are excluded from discovery and reporting, including
empty groups. Resources inside those groups are still checked by the remaining
eight resource-type queries.

The report separates `candidates` from resources tagged
`ignoredByOrphanCleanup: true` (case-insensitive key/value). It includes a UTC
timestamp, subscription scope, categories, and counts. AKS `pvc-*` disks in
resource groups ending in `-aks-node-rg`, and ASR replica disks, are excluded.
Disks must also be `Unattached` with an empty `managedBy` field. The AKS exclusion
uses `endswith`: KQL `=~` is equality, not a regular-expression match.

Other existing queries are retained as candidate heuristics, not proof of an
orphan. For example, an empty App Service plan may be intentionally reserved,
an unattached network resource may still be required, and an unallocated public
IP is not necessarily unused. Resource Graph data may lag behind current state.
Review ownership, dependencies, tags, locks, retention needs, and current Azure
state before approving any future deletion implementation. Disks require
particular care.

Restoring live execution or scheduling requires a separate reviewed change.
Do not feed this preview directly into a deletion command.

## Tests

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

Tests mock Azure CLI; no Azure resources are modified.

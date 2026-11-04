import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/orphan-cleanup.sh"
SUBSCRIPTION = "test-sub"
PRINCIPAL = "50cce126-c44a-48bb-9361-5f55868d3182"


class OrphanPreviewTests(unittest.TestCase):
    def run_preview(self, scenario="normal", arguments=()):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            status = root / "status"
            status.mkdir()
            historical = status / "deletionStatus.json"
            historical.write_text('[{"message":"historical failure"}]\n')
            stale = root / "failedDeletes.json"
            stale.write_text('{"message":"leftover"}\n')
            calls_file = root / "calls.jsonl"
            az = root / "az"
            az.write_text(
                f"#!{sys.executable}\n"
                """import json, os, sys
args = sys.argv[1:]
scenario = os.environ["SCENARIO"]
with open(os.environ["AZ_CALLS"], "a") as output:
    output.write(json.dumps(args) + "\\n")
if args[:2] == ["account", "list"]:
    if scenario == "account-error":
        sys.exit("Account lookup failed")
    print(json.dumps([{"id":"test-sub"}]))
elif args[:3] == ["role", "assignment", "list"]:
    if scenario == "role-error":
        sys.exit("Role lookup failed")
    roles = [{
        "roleDefinitionName":"Orphan Resource Cleanup Read/Delete",
        "principalId":"50cce126-c44a-48bb-9361-5f55868d3182",
        "scope":"/subscriptions/test-sub",
    }]
    if scenario == "no-role":
        roles = []
    if scenario == "rg-role":
        roles[0]["scope"] += "/resourceGroups/test-rg"
    if scenario == "wrong-principal":
        roles[0]["principalId"] = "someone-else"
    if scenario == "bad-role":
        roles[0]["scope"] = None
    if scenario == "mg-role":
        roles[0]["scope"] = "/providers/Microsoft.Management/managementGroups/SDS-Sandbox"
    if scenario == "unresolved-inherited-role":
        roles.insert(0, {"roleDefinitionName": None, "principalId": "group-id",
                         "scope": "/providers/Microsoft.Management/managementGroups/HMCTS"})
        roles[1]["scope"] = "/providers/Microsoft.Management/managementGroups/SDS-Sandbox"
    if scenario == "roles-not-array":
        roles = {"error": "unexpected"}
    print(json.dumps(roles))
elif args[:2] == ["graph", "query"]:
    query = args[args.index("-q")+1]
    scope_start = args.index("--subscriptions")+1
    assert args[scope_start:args.index("--first")] == ["test-sub"]
    assert args[args.index("--first")+1] == "1000"
    if scenario == "query-error":
        sys.exit("Resource Graph failed")
    if scenario == "bad-json":
        print("not JSON")
        sys.exit(0)
    if scenario == "bad-shape":
        print('{"data":null}')
        sys.exit(0)
    rows = []
    token = None
    def resource(name, tags=None):
        return {
            "id":"/subscriptions/test-sub/resourceGroups/test-rg/providers/Test/items/"+name,
            "subscriptionId":"test-sub", "name":name, "type":"test/items",
            "resourceGroup":"test-rg", "tags":tags,
        }
    if "microsoft.web/serverfarms" in query:
        if "--skip-token" not in args:
            rows = [resource("first"), resource("ignored", {"IgnoredByOrphanCleanup":"TRUE"})]
            token = "second-page"
        else:
            assert args[args.index("--skip-token")+1] == "second-page"
            rows = [resource("second"), resource("first")]
            if scenario == "repeated-token":
                token = "second-page"
    if scenario == "empty":
        rows, token = [], None
    if scenario == "out-of-scope":
        rows = [resource("unexpected")]
        rows[0]["subscriptionId"] = "other-sub"
    if scenario == "wrong-id":
        rows = [resource("unexpected")]
        rows[0]["id"] = "/subscriptions/other-sub/resourceGroups/test-rg"
    if scenario == "missing-token":
        print(json.dumps({"data":[], "skip_token":None, "total_records":1001}))
        sys.exit(0)
    print(json.dumps({"data":rows, "skip_token":token}))
else:
    sys.exit("Unsafe or unexpected Azure command: "+repr(args))
"""
            )
            az.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SCRIPT), *arguments],
                cwd=root,
                env={
                    **os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}",
                    "SCENARIO": scenario,
                    "AZ_CALLS": str(calls_file),
                },
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(historical.read_text(), '[{"message":"historical failure"}]\n')
            self.assertEqual(stale.read_text(), '{"message":"leftover"}\n')
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
            return result, calls

    def test_default_is_preview_with_pagination_deduplication_and_tag_exclusion(self):
        result, calls = self.run_preview()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["mode"], "preview")
        self.assertEqual(report["subscriptions"], [SUBSCRIPTION])
        self.assertEqual(report["summary"], {"candidates": 2, "ignored": 1})
        self.assertEqual({row["name"] for row in report["candidates"]}, {"first", "second"})
        self.assertEqual(report["ignored"][0]["name"], "ignored")
        self.assertRegex(report["checkedAt"], r"^\d{4}-\d{2}-\d{2}T.*Z$")
        graph_calls = [call for call in calls if call[:2] == ["graph", "query"]]
        self.assertEqual(len(graph_calls), 9)
        self.assertTrue(all("project id" in call[call.index("-q") + 1] for call in graph_calls))

    def test_explicit_dry_run(self):
        result, _ = self.run_preview(arguments=("-m", "dry-run"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_resource_groups_are_not_queried_or_reported(self):
        result, calls = self.run_preview()
        self.assertEqual(result.returncode, 0, result.stderr)
        queries = [call[call.index("-q") + 1] for call in calls if call[:2] == ["graph", "query"]]
        self.assertEqual(len(queries), 9)  # Eight resource types, plus the second page.
        self.assertTrue(all("resourcecontainers" not in query.lower() for query in queries))
        self.assertTrue(all("microsoft.resources/subscriptions/resourcegroups" not in query.lower()
                            for query in queries))
        report = json.loads(result.stdout)
        self.assertTrue(all(row["category"] != "Resource Groups"
                            for row in report["candidates"] + report["ignored"]))

    def test_management_group_role_covers_subscription(self):
        # Production assigns the cleanup role at management-group level, and inherited
        # assignments may have an unresolvable (null) role name.
        for scenario in ("mg-role", "unresolved-inherited-role"):
            with self.subTest(scenario=scenario):
                result, _ = self.run_preview(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["subscriptions"], [SUBSCRIPTION])

    def test_unsafe_or_invalid_modes_fail_before_azure(self):
        for args in (("-m", "live"), ("-m", "almost-dry-run"), ("-m",), ("unexpected",), ("-x",)):
            with self.subTest(arguments=args):
                result, calls = self.run_preview(arguments=args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])
                self.assertEqual(result.stdout, "")

    def test_no_matching_subscription_never_runs_unscoped_queries(self):
        for scenario in ("no-role", "rg-role", "wrong-principal", "bad-role"):
            with self.subTest(scenario=scenario):
                result, calls = self.run_preview(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing an unscoped query", result.stderr)
                self.assertFalse(any(call[:2] == ["graph", "query"] for call in calls))
                self.assertEqual(result.stdout, "")

    def test_discovery_and_query_failures_never_emit_success_report(self):
        for scenario in (
            "account-error", "role-error", "roles-not-array", "query-error", "bad-json",
            "bad-shape", "out-of-scope", "wrong-id", "repeated-token", "missing-token",
        ):
            with self.subTest(scenario=scenario):
                result, _ = self.run_preview(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_empty_query_results_produce_explicit_empty_preview(self):
        result, _ = self.run_preview("empty")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["summary"], {"candidates": 0, "ignored": 0})

    def test_disk_query_preserves_safety_exclusions(self):
        result, calls = self.run_preview()
        self.assertEqual(result.returncode, 0, result.stderr)
        queries = [call[call.index("-q")+1] for call in calls if call[:2] == ["graph", "query"]]
        disk_query = next(query for query in queries if "microsoft.compute/disks" in query)
        self.assertIn('name startswith "pvc-" and resourceGroup endswith "-aks-node-rg"', disk_query)
        self.assertNotIn('resourceGroup =~ "-aks-node-rg$"', disk_query)
        self.assertIn('properties.diskState =~ "Unattached"', disk_query)
        self.assertIn('managedBy == ""', disk_query)
        self.assertIn('name endswith "-ASRReplica" or name startswith "ms-asr-"', disk_query)

    def test_no_live_or_status_write_commands_in_workflow(self):
        workflow = (ROOT / ".github/workflows/orphan-cleanup.yaml").read_text()
        self.assertNotIn("schedule:", workflow)
        self.assertNotIn("PLATFORM_USER_TOKEN", workflow)
        self.assertNotIn("contents: write", workflow)
        self.assertNotIn("git push", workflow)
        self.assertNotIn("live:", workflow)
        self.assertIn("bash scripts/orphan-cleanup.sh -m dry-run", workflow)
        self.assertIn("actions/upload-artifact@v4", workflow)
        self.assertNotIn("az resource delete", SCRIPT.read_text())


if __name__ == "__main__":
    unittest.main()

"""Offline regression tests for the live harness's pass/fail decisions and no-op worker."""
import io
import json
from pathlib import Path
from types import SimpleNamespace
import subprocess
import tempfile
import unittest
import urllib.error
from unittest.mock import Mock, patch

from common import GitHub, Trace, assert_trace, field_status, git, read_events, read_with_retry, validate_checkout
from worker import ScriptedWorker
from run import Harness


def successful_trace():
    issues = {
        "P": dict(number=1, kind="feature", parent=None, blockers=[]),
        "A": dict(number=2, kind="task", parent="P", blockers=[]),
        "B": dict(number=3, kind="task", parent="P", blockers=["A"]),
        "Q": dict(number=4, kind="feature", parent=None, blockers=["P"]),
        "D": dict(number=5, kind="task", parent="Q", blockers=[]),
    }
    events = []

    def event(key, kind, role, at, **kwargs):
        events.append(dict(issue=f'GH-{issues[key]["number"]}', kind=kind, role=role, time=at,
                           thread=key + role, cwd="/tmp/" + key, **kwargs))

    def flow(key, start, review, integrate):
        event(key, "turn_start", "Ready", start)
        event(key, "status_result", "Ready", start + .1, target="In progress", success=True)
        event(key, "status_result", "Ready", review - .1, target="In review", success=True)
        event(key, "turn_start", "In review", review)
        target = "Human Review" if issues[key]["kind"] == "feature" else "Integrating"
        event(key, "status_result", "In review", review + .1, target=target, success=True, evidence={"validation": {}})
        event(key, "turn_start", "Integrating", integrate)
        event(key, "status_result", "Integrating", integrate + .1, target="Done", success=True)

    flow("P", 1, 12, 15)
    flow("A", 2, 3, 4)
    flow("B", 5, 6, 7)
    flow("Q", 16, 22, 25)
    flow("D", 17, 18, 19)
    return {"issues": issues}, events, {"P": 14, "Q": 24}


class HarnessTest(unittest.TestCase):
    def test_child_human_pause_fails_promptly_without_simulating_approval(self):
        harness = Harness.__new__(Harness)
        harness.manifest = {"issues": {
            "P": {"number": 1, "kind": "feature"},
            "A": {"number": 2, "kind": "task"},
            "Q": {"number": 3, "kind": "feature"},
        }}
        harness.report = {"samples": []}
        harness.approvals, harness.holds = {}, {}
        harness.snapshot = Mock(return_value={"running": [], "blocked": [], "dispatch_paused": None})
        harness.states = Mock(return_value={"P": "In progress", "A": "Human Review", "Q": "Ready"})
        harness.set_status = Mock()
        harness.save = Mock()
        with self.assertRaisesRegex(RuntimeError, "A: child entered Human Review"):
            harness.observe()
        harness.set_status.assert_not_called()
        self.assertEqual(harness.report["samples"][-1]["states"]["A"], "Human Review")

    def test_rate_exhaustion_reports_reset_without_token_or_response_body(self):
        error = urllib.error.HTTPError("https://api.github.com/test", 403, "Forbidden",
                                     {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1790136407"},
                                     io.BytesIO(b"private response body"))
        with patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "rate limit exhausted.*2026-09-23T04:06:47") as caught:
                GitHub("private-token").call("GET", "/test")
        self.assertNotIn("private", str(caught.exception))

    def test_generated_workflow_allows_reviewed_git_writes_without_full_access(self):
        with tempfile.TemporaryDirectory() as directory:
            harness = Harness.__new__(Harness)
            harness.directory = Path(directory)
            source = Path(__file__).resolve().parents[2] / "WORKFLOW.md"
            harness.args = SimpleNamespace(project_owner=None, repo="test/example", owner_type="user",
                                           project=1, mode="codex", workflow=str(source))
            harness.manifest = dict(run_label="test-run", clone_url="git@example.invalid:test/example.git",
                                    baseline_tree="baseline")
            harness.save = lambda: None
            with patch("run.workflow_project_id", return_value="symphony-project"):
                config = json.loads(harness.workflow().read_text().split("---", 2)[1])
            self.assertEqual(config["codex"]["project_id"], "symphony-project")
            self.assertEqual(config["codex"]["approval_policy"], "on-request")
            self.assertEqual(config["codex"]["thread_sandbox"], "workspace-write")
            self.assertEqual(config["codex"]["turn_sandbox_policy"]["type"], "workspaceWrite")
            self.assertEqual(config["polling"]["interval_ms"], 30000)

            with patch("run.workflow_project_id", return_value=None):
                config = json.loads(harness.workflow().read_text().split("---", 2)[1])
            self.assertNotIn("project_id", config["codex"])

            harness.args.mode = "scripted"
            with patch("run.workflow_project_id") as lookup:
                config = json.loads(harness.workflow().read_text().split("---", 2)[1])
            lookup.assert_not_called()
            self.assertNotIn("project_id", config["codex"])

            harness.manifest["model_routing"] = json.loads((Path(__file__).parent / "scenario.json").read_text())["model_routing"]
            config = json.loads(harness.workflow().read_text().split("---", 2)[1])["codex"]
            self.assertEqual((config["model"], config["reasoning_effort"]), ("gpt-6-sol", "high"))
            self.assertEqual((config["review_model"], config["review_reasoning_effort"]), ("gpt-6-sol", "high"))
            self.assertEqual((config["parent_review_model"], config["parent_review_reasoning_effort"]), ("gpt-6-astra", "high"))
            self.assertEqual((config["integration_model"], config["integration_reasoning_effort"]), ("gpt-6-sol", "high"))

    def test_human_review_blocker_is_never_treated_as_merge_approval(self):
        harness = Harness.__new__(Harness)
        harness.repo_path = "/repos/test/example"
        harness.manifest, _, _ = successful_trace()
        harness.report = {}
        harness.github = Mock()
        body = "## Agent Workpad\nBlockers: cannot open '.git/FETCH_HEAD': Permission denied"
        harness.github.pages.return_value = [{"body": body}]
        with self.assertRaisesRegex(RuntimeError, "no successful feature review.*Permission denied"):
            harness.verify_pause("P", {"P": "Human Review", "A": "Ready", "B": "Ready"})
        harness.github.call.assert_not_called()
        self.assertEqual(harness.report["workpads"]["P"], body)

    def test_human_approval_requires_children_done_and_current_reviewed_sha(self):
        harness = Harness.__new__(Harness)
        harness.repo_path = "/repos/test/example"
        harness.manifest, _, _ = successful_trace()
        harness.manifest["baseline_tree"] = "unchanged"
        harness.report = {"checks": {}}
        harness.github = Mock()
        body = '## Agent Workpad\nReview: ' + json.dumps({"sha": "a" * 40})
        harness.github.pages.return_value = [{"body": body}]
        states = dict(P="Human Review", A="Done", B="In review", Q="Ready", D="Ready")
        with self.assertRaisesRegex(RuntimeError, "before children Done"):
            harness.verify_pause("P", states)
        harness.github.call.assert_not_called()
        states["B"] = "Done"
        harness.github.call.side_effect = [
            {"sha": "main", "commit": {"tree": {"sha": "unchanged"}}},
            {"sha": "b" * 40, "commit": {"tree": {"sha": "unchanged"}}},
        ]
        with self.assertRaisesRegex(RuntimeError, "changed since review"):
            harness.verify_pause("P", states)

    def test_new_project_item_search_lag_is_a_retryable_read(self):
        harness = Harness.__new__(Harness)
        harness.field = {"id": 10}
        harness.project = "/users/test/projectsV2/1"
        harness.manifest = {"issues": {"P": {"item_id": 42}}}
        class API:
            def pages(self, path):
                self.path = path
                return []
        harness.github = API()
        with self.assertRaisesRegex(OSError, "not visible"):
            harness.read_states()
        self.assertNotIn("q=", harness.github.path)

    def test_busy_snapshot_retries_but_has_a_deadline(self):
        calls = iter([TimeoutError(), {"running": []}])
        def reader():
            value = next(calls)
            if isinstance(value, Exception):
                raise value
            return value
        self.assertEqual(read_with_retry(reader, clock=lambda: 0, sleep=lambda _: None), {"running": []})
        clock = iter([0, 61])
        with self.assertRaises(TimeoutError):
            read_with_retry(lambda: (_ for _ in ()).throw(TimeoutError()), clock=lambda: next(clock))

    def test_valid_role_and_dependency_trace(self):
        assert_trace(*successful_trace())

    def test_model_routing_requires_actual_thread_and_turn_settings(self):
        manifest, events, approvals = successful_trace()
        manifest["model_routing"] = {
            "implementation": {"model": "standard", "effort": "medium"},
            "review": {"model": "reviewer", "effort": "high"},
            "integration": {"model": "integrator", "effort": "high"},
            "issues": {"A": {"model": "small", "effort": "low"}},
        }
        for event in events:
            if event["kind"] == "turn_start":
                role = "review" if event["role"] == "In review" else "integration" if event["role"] == "Integrating" else "implementation"
                choice = manifest["model_routing"][role]
                if event["issue"] == "GH-2" and role == "implementation":
                    choice = manifest["model_routing"]["issues"]["A"]
                event.update(choice, thread_model=choice["model"])
        assert_trace(manifest, events, approvals)
        next(event for event in events if event["kind"] == "turn_start" and event["issue"] == "GH-2")["model"] = "wrong"
        with self.assertRaisesRegex(RuntimeError, "incorrect implementation model routing"):
            assert_trace(manifest, events, approvals)

    def test_final_done_colors_without_execution_evidence_cannot_pass(self):
        manifest, _, approvals = successful_trace()
        with self.assertRaisesRegex(RuntimeError, "reuse one workspace|missing role"):
            assert_trace(manifest, [], approvals)

    def test_current_policy_uses_high_effort_and_distinct_parent_and_child_reviewers(self):
        manifest, events, approvals = successful_trace()
        routing = json.loads((Path(__file__).parent / "scenario.json").read_text())["model_routing"]
        manifest["model_routing"] = routing
        identities = {f'GH-{issue["number"]}': (key, issue) for key, issue in manifest["issues"].items()}
        for event in events:
            if event["kind"] != "turn_start":
                continue
            key, issue = identities[event["issue"]]
            role = "review" if event["role"] == "In review" else "integration" if event["role"] == "Integrating" else "implementation"
            if role == "review" and issue["kind"] == "feature":
                role = "parent_review"
            choice = routing.get("issues", {}).get(key, routing[role]) if role == "implementation" else routing[role]
            self.assertEqual(choice["effort"], "high")
            event.update(choice, thread_model=choice["model"])
        assert_trace(manifest, events, approvals)

        for kind, wrong_model in (("feature", "gpt-6-sol"), ("task", "gpt-6-astra")):
            event = next(e for e in events if e["kind"] == "turn_start" and e["role"] == "In review"
                         and identities[e["issue"]][1]["kind"] == kind)
            original = event["model"]
            event.update(model=wrong_model, thread_model=wrong_model)
            with self.assertRaisesRegex(RuntimeError, "incorrect review model routing"):
                assert_trace(manifest, events, approvals)
            event.update(model=original, thread_model=original)

    def test_dependency_started_early_is_rejected(self):
        manifest, events, approvals = successful_trace()
        for event in events:
            if event["issue"] == "GH-3" and event["kind"] == "turn_start":
                event["time"] = 3
        with self.assertRaisesRegex(RuntimeError, "before A Done"):
            assert_trace(manifest, events, approvals)

    def test_reused_reviewer_thread_is_rejected(self):
        manifest, events, approvals = successful_trace()
        for event in events:
            if event["issue"] == "GH-2" and event["role"] == "In review":
                event["thread"] = "AReady"
        with self.assertRaisesRegex(RuntimeError, "reused"):
            assert_trace(manifest, events, approvals)

    def test_parent_integrated_before_human_approval_is_rejected(self):
        manifest, events, approvals = successful_trace()
        approvals["P"] = 20
        with self.assertRaisesRegex(RuntimeError, "before controller approval"):
            assert_trace(manifest, events, approvals)

    def test_parent_review_before_children_done_is_rejected(self):
        manifest, events, approvals = successful_trace()
        for event in events:
            if event["issue"] == "GH-1" and event["kind"] == "turn_start" and event["role"] == "In review":
                event["time"] = 2
        with self.assertRaisesRegex(RuntimeError, "before child"):
            assert_trace(manifest, events, approvals)

    def test_protocol_recorder_tracks_successful_tools_without_recording_prompts(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = Trace(directory)
            trace.observe("symphony", {"method": "thread/start", "params": {"model": "small"}})
            trace.observe("worker", {"id": 2, "result": {"thread": {"id": "t1"}}})
            trace.observe("symphony", {"method": "turn/start", "params": {"model": "small", "effort": "low", "input": [
                {"text": "Harness issue: GH-8\nHarness role: In review\nprivate prompt"}]}})
            trace.observe("worker", {"id": 9, "method": "item/tool/call", "params": {
                "tool": "set_project_status", "arguments": {"status": "Integrating"}}})
            trace.observe("symphony", {"id": 9, "result": {"success": True}})
            events = read_events(directory)
            self.assertEqual(events[-1]["thread"], "t1")
            self.assertTrue(events[-1]["success"])
            self.assertEqual((events[0]["thread_model"], events[0]["model"], events[0]["effort"]), ("small", "small", "low"))
            self.assertNotIn("private prompt", trace.path.read_text())

    def test_project_option_shapes(self):
        field = {"id": 10, "options": [{"id": "r", "name": {"raw": "Ready"}}]}
        for value in ("r", {"id": "r"}, {"name": {"raw": "Ready"}}, "Ready"):
            self.assertEqual(field_status({"fields": [{"id": 10, "value": value}]}, field), "Ready")

    def test_empty_commit_and_merge_preserve_tree_and_detect_file_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            git(directory, "init", "-b", "main")
            identity = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"]
            git(directory, *identity, "commit", "--allow-empty", "-m", "initial")
            tree = git(directory, "rev-parse", "HEAD^{tree}")
            initial = git(directory, "rev-parse", "HEAD")
            git(directory, "switch", "-c", "task/GH-1")
            git(directory, *identity, "commit", "--allow-empty", "-m", "noop")
            child = git(directory, "rev-parse", "HEAD")
            self.assertNotEqual(initial, child)
            git(directory, "switch", "main")
            git(directory, *identity, "merge", "--no-ff", "--no-edit", child)
            validate_checkout(directory, tree)
            Path(directory, "unexpected.txt").write_text("wrong")
            with self.assertRaisesRegex(RuntimeError, "file changes"):
                validate_checkout(directory, tree)

    def test_scripted_worker_uses_normal_tool_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            worker = ScriptedWorker({}, Trace(directory))
            response = {"id": 101, "result": {"success": True, "output": '{"body":null}'}}
            with patch("sys.stdin", io.StringIO(json.dumps(response) + "\n")), patch("sys.stdout", io.StringIO()) as output:
                self.assertEqual(worker.tool("agent_workpad", {}), {"body": None})
                call = json.loads(output.getvalue())
                self.assertEqual(call["method"], "item/tool/call")


if __name__ == "__main__":
    unittest.main()

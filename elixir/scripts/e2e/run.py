"""Run a post-planning no-op scenario against real GitHub and the real scheduler."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

from common import GitHub, STATES, assert_trace, field_status, raw_name, read_events, read_with_retry, require, write_json

HERE = Path(__file__).resolve().parent
ELIXIR = HERE.parents[1]


def workflow_project_id(path):
    """Use Symphony's YAML parser without printing the workflow's other settings."""
    expression = (
        '[path] = System.argv(); '
        '[_, front, _] = path |> File.read!() |> String.split("---", parts: 3); '
        'config = YamlElixir.read_from_string!(front); '
        'IO.write(Jason.encode!(get_in(config, ["codex", "project_id"])))'
    )
    result = subprocess.run(
        ["mise", "exec", "--", "mix", "run", "--no-start", "--no-compile", "-e", expression, "--", str(Path(path).resolve())],
        cwd=ELIXIR, capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


class Harness:
    def __init__(self, args):
        self.args = args
        self.github = GitHub(os.environ.get("GITHUB_TOKEN"))
        self.repo_path = "/repos/" + args.repo
        owner = args.project_owner or args.repo.split("/")[0]
        self.project = f'/{"users" if args.owner_type == "user" else "orgs"}/{owner}/projectsV2/{args.project}'
        self.run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
        if args.resume_setup:
            path = Path(args.resume_setup).resolve()
            self.manifest = json.loads(path.read_text(encoding="utf-8"))
            self.directory, self.run_id = path.parent, self.manifest["run_id"]
            require(not read_events(self.directory / "events"), "Only undispatched setup can resume")
            require(self.manifest["repo"] == args.repo and self.manifest["project"] == self.project,
                    "Resume destination differs")
            require(self.manifest["mode"] == args.mode, "Resume worker mode differs")
            require(bool(self.manifest.get("model_routing")) == args.model_routing, "Resume model-routing mode differs")
            if (self.directory / "report.json").exists():
                (self.directory / "report.json").replace(self.directory / ("setup-failure-" + uuid.uuid4().hex + ".json"))
        else:
            self.directory = Path(args.output).resolve() / self.run_id
            self.directory.mkdir(parents=True)
            self.manifest = dict(run_id=self.run_id, repo=args.repo, project=self.project,
                                 mode=args.mode, issues={}, run_label="symphony-e2e-" + self.run_id)
        self.approvals, self.holds = {}, {}
        self.process = None
        self.report = dict(result="running", run_id=self.run_id, checks={}, samples=[], approvals=self.approvals)
        self.save()

    def save(self):
        write_json(self.directory / "manifest.json", self.manifest)
        write_json(self.directory / "report.json", self.report)
        lines = ["# Symphony no-op acceptance run", "", f"Result: **{self.report['result']}**",
                 f"Mode: {self.args.mode}; run: {self.run_id}", "",
                 "| Issue | Kind | Latest observed status |", "| --- | --- | --- |"]
        states = self.report["samples"][-1]["states"] if self.report["samples"] else {}
        for key, issue in self.manifest["issues"].items():
            lines.append(f"| [{key} / GH-{issue['number']}]({issue['url']}) | {issue['kind']} | {states.get(key, 'setup')} |")
        lines += ["", "Checks:", ""]
        lines += [f"- {'PASS' if passed else 'FAIL'}: {name.replace('_', ' ')}" for name, passed in self.report["checks"].items()]
        if self.report.get("error"):
            lines += ["", "Failure:", "", "```text", self.report["error"], "```"]
        if self.report.get("quarantined"):
            lines += ["", "Moved to Backlog after failure: " + ", ".join(self.report["quarantined"])]
        if self.report.get("quarantine_failed"):
            lines += ["", "Manual action: put these test items in Backlog: " + ", ".join(self.report["quarantine_failed"])]
        lines += ["", "Empty commits change Git history but must not change tracked file contents.",
                  "Detailed evidence: [report.json](report.json). Test artifacts are retained."]
        (self.directory / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    def setup(self):
        repository = self.github.call("GET", self.repo_path)
        require(repository["default_branch"] == "main", "Harness requires the workflow's main branch")
        baseline = self.github.call("GET", self.repo_path + "/commits/main")
        if self.args.resume_setup:
            require(self.manifest["baseline_sha"] == baseline["sha"], "Main moved since setup; create a new run")
        self.manifest.update(baseline_sha=baseline["sha"], baseline_tree=baseline["commit"]["tree"]["sha"])
        fields = self.github.pages(self.project + "/fields?per_page=100")
        self.field = next((field for field in fields if field["name"] == "Status"), None)
        require(self.field is not None, "Project needs the Status field")
        self.options = {raw_name(option["name"]): option["id"] for option in self.field["options"]}
        require(set(STATES) <= self.options.keys(), "Project is missing one or more workflow statuses")
        scenario = json.loads((HERE / "scenario.json").read_text(encoding="utf-8"))
        if self.args.model_routing:
            self.prepare_model_routing(fields, scenario["model_routing"])
        # Fail before issue creation if worker clone/push authentication cannot read the repository.
        result = subprocess.run(["git", "ls-remote", repository["ssh_url"], "refs/heads/main"],
                                capture_output=True, text=True, timeout=45,
                                env=dict(os.environ, GIT_SSH_COMMAND="ssh -o BatchMode=yes"))
        require(result.returncode == 0 and baseline["sha"] in result.stdout, "Git SSH read authentication failed")
        self.manifest["clone_url"] = repository["ssh_url"]
        if self.args.resume_setup:
            require(set(self.manifest["issues"]) == {"P", "A", "B", "C", "Q", "D"}, "Setup is incomplete")
            self.verify_creation()
            self.report["checks"]["created_native_task_graph"] = True
            self.save()
            return
        labels = {label["name"] for label in self.github.pages(self.repo_path + "/labels?per_page=100")}
        for name in ["symphony", "type:feature", "type:task", self.manifest["run_label"]]:
            if name not in labels:
                self.github.call("POST", self.repo_path + "/labels", {"name": name, "color": "64748b"})
        for definition in scenario["issues"]:
            key = definition["key"]
            body = ("## Objective\nExercise the normal Symphony lifecycle without changing any tracked files.\n"
                    "## Acceptance\n```symphony-acceptance\n" + json.dumps({"version": 1, "criteria": [{
                        "id": "A1", "description": "Clean checkout; tracked tree equals " + self.manifest["baseline_tree"],
                        "validation": {"kind": "review", "instructions": "Verify clean git status and exact baseline tree equality."}
                    }]}) + "\n```\n"
                    "## Validation\nRun git status --porcelain (must be empty), then git rev-parse HEAD^{tree}; "
                    "compare with A1. Do not edit files.\n"
                    "## Scope\nEmpty commits and merges only. Do not modify or add code, tests, documentation, "
                    "or configuration. Do not close issues or edit relationships.\n"
                    f"Harness run: {self.run_id}; fixture key: {key}.\n")
            issue = self.github.call("POST", self.repo_path + "/issues", {
                "title": f"[Symphony no-op {self.run_id}] {key}: {definition['kind']}", "body": body,
                "labels": ["symphony", "type:" + definition["kind"], self.manifest["run_label"]]})
            self.manifest["issues"][key] = dict(definition, number=issue["number"], id=issue["id"], url=issue["html_url"])
            self.save()  # Retain IDs immediately if a later API write fails.
            item = self.github.call("POST", self.project + "/items", {"type": "Issue", "id": issue["id"]})
            self.manifest["issues"][key]["item_id"] = item["id"]
            self.save()
            self.set_status(key, "Backlog")
            if self.args.model_routing and key in self.manifest["model_routing"]["issues"]:
                choice = self.manifest["model_routing"]["issues"][key]
                values = [{"id": self.model_fields[name]["id"], "value": next(option["id"] for option in self.model_fields[name]["options"]
                           if raw_name(option["name"]) == choice[name])} for name in ("model", "effort")]
                self.github.call("PATCH", f'{self.project}/items/{item["id"]}', {"fields": values})
        for key, issue in self.manifest["issues"].items():
            if issue["parent"]:
                parent = self.manifest["issues"][issue["parent"]]
                self.github.call("POST", f'{self.repo_path}/issues/{parent["number"]}/sub_issues', {"sub_issue_id": issue["id"]})
            for blocker in issue["blockers"]:
                self.github.call("POST", f'{self.repo_path}/issues/{issue["number"]}/dependencies/blocked_by',
                                 {"issue_id": self.manifest["issues"][blocker]["id"]})
        self.verify_creation()
        self.report["checks"]["created_native_task_graph"] = True
        self.save()

    def set_status(self, key, status):
        issue = self.manifest["issues"][key]
        self.github.call("PATCH", f'{self.project}/items/{issue["item_id"]}',
                         {"fields": [{"id": self.field["id"], "value": self.options[status]}]})

    def prepare_model_routing(self, fields, defaults):
        config = self.manifest.setdefault("model_routing", defaults)
        self.model_fields = {}
        for key, name in (("model", "Model"), ("effort", "Reasoning effort")):
            matches = [field for field in fields if field["name"] == name and field.get("data_type") == "single_select"]
            require(len(matches) == 1, f"Create Project single-select field {name!r} before a model-routing run")
            field = self.model_fields[key] = matches[0]
            values = {raw_name(option["name"]) for option in field["options"]}
            require(all(choice[key] in values for choice in config["issues"].values()), f"{name}: missing fixture options")
        self.save()

    def states(self):
        return read_with_retry(self.read_states)

    def read_states(self):
        # Search indexing can lag project creation; read membership directly by item ID.
        query = urllib.parse.urlencode({"per_page": 100, "fields": self.field["id"]})
        items = {item["id"]: item for item in self.github.pages(self.project + "/items?" + query)}
        if any(issue["item_id"] not in items for issue in self.manifest["issues"].values()):
            raise OSError("New project membership is not visible yet")
        return {key: field_status(items[issue["item_id"]], self.field) for key, issue in self.manifest["issues"].items()}

    def verify_creation(self):
        require(set(self.states().values()) == {"Backlog"}, "Created issues did not remain in Backlog")
        if self.manifest.get("model_routing"):
            query = urllib.parse.urlencode({"per_page": 100, "fields": ",".join(str(field["id"]) for field in self.model_fields.values())})
            items = {item["id"]: item for item in self.github.pages(self.project + "/items?" + query)}
            for key, issue in self.manifest["issues"].items():
                expected = self.manifest["model_routing"]["issues"].get(key, {})
                for name, field in self.model_fields.items():
                    require(field_status(items[issue["item_id"]], field) == expected.get(name), f"{key}: {name} was not saved")
        for key, issue in self.manifest["issues"].items():
            base = f'{self.repo_path}/issues/{issue["number"]}'
            raw = self.github.call("GET", base)
            labels = {label["name"] for label in raw["labels"]}
            require({"symphony", "type:" + issue["kind"], self.manifest["run_label"]} <= labels, f"{key}: labels differ")
            blockers = self.github.pages(base + "/dependencies/blocked_by?per_page=100")
            expected = {self.manifest["issues"][blocker]["id"] for blocker in issue["blockers"]}
            require({value["id"] for value in blockers} == expected, f"{key}: native blockers differ")
            if issue["parent"]:
                parent = self.github.call("GET", base + "/parent")
                require(parent["id"] == self.manifest["issues"][issue["parent"]]["id"], f"{key}: native parent differs")
            children = self.github.pages(base + "/sub_issues?per_page=100")
            expected = {value["id"] for value in self.manifest["issues"].values() if value["parent"] == key}
            require({value["id"] for value in children} == expected, f"{key}: native children differ")

    def workflow(self):
        manifest_path = (self.directory / "manifest.json").as_posix()
        command = " ".join(shlex.quote(arg) for arg in [Path(sys.executable).as_posix(), (HERE / "worker.py").as_posix(),
                                                       "--manifest", manifest_path, "--mode", self.args.mode])
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        owner = self.args.project_owner or self.args.repo.split("/")[0]
        config = {
            "tracker": {"kind": "github", "provider": {"repo": self.args.repo, "token": "$GITHUB_TOKEN",
                "project_owner": owner, "project_owner_type": self.args.owner_type, "project_number": self.args.project},
                "required_labels": ["symphony", self.manifest["run_label"]],
                "active_states": STATES[1:5], "terminal_states": ["Done"]},
            "polling": {"interval_ms": 30000 if self.args.mode == "codex" else 5000},
            "workspace": {"root": (self.directory / "workspaces").as_posix(), "retain_terminal": True},
            "hooks": {"after_create": "git clone " + shlex.quote(self.manifest["clone_url"]) + " .",
                      "before_run": "git rev-parse --verify HEAD && git fetch origin --prune", "timeout_ms": 120000},
            "agent": {"max_concurrent_agents": 2, "max_turns": 8, "max_retry_backoff_ms": 30000,
                      "recovery_enabled": True, "checkpoint_interval_turns": 3,
                      "max_consecutive_failures": 3, "max_no_progress_runs": 3, "max_rework_cycles": 3,
                      "max_concurrent_agents_by_state": {"Integrating": 1}},
            "codex": {"command": command, "approval_policy": "on-request", "thread_sandbox": "workspace-write",
                      "turn_sandbox_policy": {"type": "workspaceWrite", "networkAccess": True},
                      "turn_timeout_ms": 300000, "stall_timeout_ms": 180000},
            "server": {"host": "127.0.0.1", "port": self.port}}
        if self.manifest.get("model_routing"):
            routing = self.manifest["model_routing"]
            for role, prefix in (("implementation", ""), ("review", "review_"), ("parent_review", "parent_review_"), ("integration", "integration_")):
                if role not in routing:
                    continue
                config["codex"][prefix + "model"] = routing[role]["model"]
                config["codex"][prefix + "reasoning_effort"] = routing[role]["effort"]
        if self.args.mode == "codex":
            project_id = workflow_project_id(self.args.workflow)
            if project_id is not None:
                config["codex"]["project_id"] = project_id
        production = Path(self.args.workflow).read_text(encoding="utf-8").split("---", 2)[2]
        instructions = (
            "\nHarness issue: {{ issue.identifier }}\nHarness role: {{ issue.state }}\n"
            "This is an authorized no-op acceptance run. The lifecycle below applies, with these scope overrides:\n"
            "Never change, create or remove tracked files, including tests and documentation.\n"
            "Children make one git commit --allow-empty with subject 'Symphony no-op {{ issue.identifier }}'.\n"
            "Use ordinary branch creation, fresh review and no-force merges. Do not mark bugs or invent bug fixes.\n"
            "Validation is git status --porcelain (empty) and git rev-parse HEAD^{tree}, which must equal "
            + self.manifest["baseline_tree"] + ". Validate before every push and approval.\n"
            "Use that exact comparison as the validation.command and pass evidence through set_project_status.\n"
            "Do not run gameplay tests or edit source files. Never approve Human Review yourself.\n"
            "Record your thread ID in the compact workpad. Commit identity may be set with per-command "
            "git -c user.name='Symphony E2E' -c user.email='e2e@example.invalid'; do not edit Git configuration.\n")
        path = self.directory / "WORKFLOW.md"
        path.write_text("---\n" + json.dumps(config, indent=2) + "\n---\n" + instructions + production, encoding="utf-8")
        self.manifest["workflow"] = str(path)
        self.save()
        return path

    def start(self, workflow):
        command = ["mise", "-C", str(ELIXIR), "exec", "--", "escript", str(ELIXIR / "bin/symphony"),
                   str(workflow), "--logs-root", str(self.directory), "--i-understand-that-this-will-be-running-without-the-usual-guardrails"]
        if os.name == "nt":
            escaped = " ".join("'" + arg.replace("'", "''") + "'" for arg in command)
            command = ["powershell.exe", "-NoProfile", "-Command", "& " + escaped + "; exit $LASTEXITCODE"]
        self.console = (self.directory / "console.log").open("w", encoding="utf-8")
        self.process = subprocess.Popen(command, stdout=self.console, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
            start_new_session=os.name != "nt")
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            require(self.process.poll() is None, "Symphony exited during startup; inspect console.log")
            try:
                self.snapshot()
                return
            except (OSError, ValueError):
                time.sleep(1)
        raise RuntimeError("Symphony state API did not become ready")

    def snapshot(self):
        return read_with_retry(self.read_snapshot)

    def read_snapshot(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/api/v1/state", timeout=5) as response:
            value = json.load(response)
        if "error" in value:
            raise OSError("Scheduler state temporarily unavailable")
        return value

    def observe(self):
        snapshot = self.snapshot()
        self.report["tracker_api"] = snapshot.get("tracker_api")
        running = snapshot["running"]
        require(len(running) <= 2, "More than two concurrent workers")
        require(sum(issue["state"] == "Integrating" for issue in running) <= 1, "Concurrent integration workers")
        identities = {f'GH-{issue["number"]}' for issue in self.manifest["issues"].values()}
        require(all(issue["issue_identifier"] in identities for issue in running), "Harness dispatched unrelated issue")
        require(snapshot.get("dispatch_paused") is None, "Dispatch paused; quota exhaustion is not an E2E pass")
        require(not snapshot.get("blocked"), "Worker needs operator input; this unattended acceptance run cannot continue")
        states = self.states()
        self.report["samples"].append({"time": time.time(), "states": states,
                                      "running": [{k: issue.get(k) for k in ("issue_identifier", "state", "session_id", "workspace_path")} for issue in running]})
        for key, issue in self.manifest["issues"].items():
            require(issue["kind"] != "task" or states[key] != "Human Review",
                    f"{key}: child entered Human Review; inspect its workpad before rerunning")
        for key in ("P", "Q"):
            if key in self.approvals:
                continue
            if states[key] == "Human Review":
                began = self.holds.setdefault(key, time.monotonic())
                identity = f'GH-{self.manifest["issues"][key]["number"]}'
                # Reconciliation gets one poll to stop the previous reviewer.
                if time.monotonic() - began >= 10:
                    require(not any(issue["issue_identifier"] == identity for issue in running), "Worker continued during human pause")
                minimum_pause = max(self.args.pause_seconds, 60 if self.args.mode == "codex" else 15)
                if time.monotonic() - began >= minimum_pause:
                    self.verify_pause(key, states)
                    self.approvals[key] = time.time()
                    self.save()  # The approval audit must precede the board mutation.
                    self.set_status(key, "Integrating")
                    print(f"{key}: pause verified; controller simulates human approval", flush=True)
            else:
                require(key not in self.holds, f"{key}: left Human Review without controller approval")
        self.save()
        return states

    def verify_pause(self, key, states):
        issue = self.manifest["issues"][key]
        comments = self.github.pages(f'{self.repo_path}/issues/{issue["number"]}/comments?per_page=100')
        pads = [comment["body"] for comment in comments if comment["body"].startswith("## Agent Workpad")]
        require(len(pads) == 1, f"{key}: Human Review requires exactly one workpad")
        self.report.setdefault("workpads", {})[key] = pads[0]
        records = [line[8:] for line in pads[0].splitlines() if line.startswith("Review: ")]
        blockers = next((line for line in pads[0].splitlines() if line.startswith("Blockers:")), "No blocker detail recorded")
        require(len(records) == 1, f"{key}: Human Review has no successful feature review; {blockers}")
        review = json.loads(records[0])
        require(isinstance(review, dict) and re.fullmatch(r"[0-9a-f]{40}", str(review.get("sha", ""))),
                f"{key}: invalid feature review record")
        children = [name for name, child in self.manifest["issues"].items() if child["parent"] == key]
        require(all(states[child] == "Done" for child in children), f"{key}: Human Review before children Done; {blockers}")
        main = self.github.call("GET", self.repo_path + "/commits/main")
        require(main["commit"]["tree"]["sha"] == self.manifest["baseline_tree"], "Main file tree changed during run")
        feature = self.github.call("GET", self.repo_path + "/commits/feature/GH-" + str(issue["number"]))
        require(review["sha"] == feature["sha"], f"{key}: feature changed since review")
        require(feature["commit"]["tree"]["sha"] == self.manifest["baseline_tree"], "Feature changed files")
        comparison = self.github.call("GET", self.repo_path + f'/compare/{feature["sha"]}...{main["sha"]}')
        require(comparison["merge_base_commit"]["sha"] != feature["sha"], "Feature reached main before human approval")
        if key == "P":
            require(states["Q"] == states["D"] == "Ready", "Feature dependency released during human pause")
        self.report["checks"][key + "_human_pause"] = True

    def finish(self):
        events = read_events(self.directory / "events")
        assert_trace(self.manifest, events, self.approvals)
        self.report["checks"]["role_and_dependency_trace"] = True
        main = self.github.call("GET", self.repo_path + "/commits/main")
        require(main["commit"]["tree"]["sha"] == self.manifest["baseline_tree"], "Final main tree changed")
        for key, issue in self.manifest["issues"].items():
            branch = ("feature/" if issue["kind"] == "feature" else "task/") + f'GH-{issue["number"]}'
            commit = self.github.call("GET", self.repo_path + "/commits/" + branch)
            require(commit["commit"]["tree"]["sha"] == self.manifest["baseline_tree"], f"{key}: source tree changed")
            require(commit["sha"] != self.manifest["baseline_sha"], f"{key}: no distinct no-op commit")
            if issue["kind"] == "task":
                require(commit["commit"]["message"].splitlines()[0] == f'Symphony no-op GH-{issue["number"]}',
                        f"{key}: missing its own named empty commit")
            comparison = self.github.call("GET", self.repo_path + f'/compare/{commit["sha"]}...{main["sha"]}')
            require(comparison["merge_base_commit"]["sha"] == commit["sha"], f"{key}: reviewed work missing from main")
            if issue["parent"]:
                parent_number = self.manifest["issues"][issue["parent"]]["number"]
                parent_commit = self.github.call("GET", self.repo_path + f"/commits/feature/GH-{parent_number}")
                comparison = self.github.call("GET", self.repo_path + f'/compare/{commit["sha"]}...{parent_commit["sha"]}')
                require(comparison["merge_base_commit"]["sha"] == commit["sha"], f"{key}: work missing from native parent branch")
            self.report.setdefault("commits", {})[key] = commit["sha"]
            comments = self.github.pages(f'{self.repo_path}/issues/{issue["number"]}/comments?per_page=100')
            pads = [comment for comment in comments if comment["body"].startswith("## Agent Workpad")]
            require(len(pads) == 1 and len(pads[0]["body"].splitlines()) <= 40, f"{key}: invalid workpad")
            records = [line[8:] for line in pads[0]["body"].splitlines() if line.startswith("Review: ")]
            require(len(records) == 1 and json.loads(records[0])["sha"] == commit["sha"], f"{key}: review mismatch")
            self.report.setdefault("workpads", {})[key] = pads[0]["body"]
        self.report["checks"]["unchanged_tracked_trees_and_final_ancestry"] = True
        self.report["commits"]["main"] = main["sha"]
        self.report["events"] = events
        self.report["result"] = "passed"
        self.save()

    def stop(self):
        if self.process and self.process.poll() is None:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(self.process.pid), "/T", "/F"], capture_output=True, timeout=30)
            else:
                import signal
                os.killpg(self.process.pid, signal.SIGTERM)
            self.process.wait(timeout=30)
        if hasattr(self, "console"):
            self.console.close()

    def run(self):
        try:
            self.setup()
            workflow = self.workflow()
            self.start(workflow)
            time.sleep(35 if self.args.mode == "codex" else 6)
            require(not self.snapshot()["running"], "Backlog dispatched a worker")
            self.report["checks"]["backlog_pause"] = True
            for key in self.manifest["issues"]:
                self.set_status(key, "Ready")
            deadline = time.monotonic() + self.args.timeout_minutes * 60
            previous = None
            while time.monotonic() < deadline:
                require(self.process.poll() is None, "Symphony exited; inspect console.log")
                states = self.observe()
                if states != previous:
                    print(" | ".join(f"{key}: {state}" for key, state in states.items()), flush=True)
                    previous = states
                if all(state == "Done" for state in states.values()):
                    time.sleep(2)  # Allow the final tool receipt to reach the protocol recorder.
                    self.finish()
                    return
                time.sleep(10 if self.args.mode == "codex" else 3)
            raise RuntimeError("Timed out before all tasks completed")
        except BaseException as error:
            self.report.update(result="failed", error=str(error), events=read_events(self.directory / "events"))
            self.save()
            raise
        finally:
            self.stop()
            if self.report["result"] != "passed":
                # Prevent the normal ArtCom scheduler from picking up abandoned fixtures.
                for key, issue in self.manifest["issues"].items():
                    if "item_id" in issue:
                        try:
                            self.set_status(key, "Backlog")
                            self.report.setdefault("quarantined", []).append(key)
                        except Exception:
                            self.report.setdefault("quarantine_failed", []).append(key)
                self.save()
            print("Report: " + str(self.directory / "report.json"), flush=True)


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--project", required=True, type=int)
    parser.add_argument("--project-owner")
    parser.add_argument("--owner-type", choices=["user", "organization"], default="user")
    parser.add_argument("--mode", choices=["scripted", "codex"], default="scripted")
    parser.add_argument("--workflow", default=str(ELIXIR / "WORKFLOW.md"))
    parser.add_argument("--output", default=str(ELIXIR / "log/e2e"))
    parser.add_argument("--pause-seconds", type=int, default=20)
    parser.add_argument("--timeout-minutes", type=int, default=30)
    parser.add_argument("--resume-setup", help="Reuse a fully-created Backlog fixture that never dispatched a worker")
    parser.add_argument("--model-routing", action="store_true", help="Verify Project model/effort fields and per-role wire settings")
    args = parser.parse_args()
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo), "Invalid repository")
    require(args.project > 0 and args.pause_seconds >= 15 and args.timeout_minutes > 0, "Invalid timing/project configuration")
    return args


if __name__ == "__main__":
    Harness(arguments()).run()

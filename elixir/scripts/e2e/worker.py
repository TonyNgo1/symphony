"""A scripted app-server peer, or transparent real-Codex protocol recorder.

No GitHub credentials are needed here: every tracker operation uses Symphony's tools.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import threading
import uuid

from common import Trace, git, require, validate_checkout


class ScriptedWorker:
    def __init__(self, manifest, trace):
        self.manifest = manifest
        self.trace = trace
        self.thread = "scripted-" + uuid.uuid4().hex
        self.turn = None
        self.call_id = 100
        self.cwd = None

    def send(self, packet):
        self.trace.observe("worker", packet)
        print(json.dumps(packet), flush=True)

    def read(self):
        line = sys.stdin.readline()
        require(bool(line), "Symphony closed the protocol")
        packet = json.loads(line)
        self.trace.observe("symphony", packet)
        return packet

    def tool(self, name, arguments):
        self.call_id += 1
        call_id = self.call_id
        self.send({"id": call_id, "method": "item/tool/call", "params": {
            "tool": name, "arguments": arguments, "callId": str(call_id),
            "threadId": self.thread, "turnId": self.turn}})
        while True:
            reply = self.read()
            if reply.get("id") == call_id:
                result = reply.get("result", {})
                require(result.get("success"), f"Tool {name} rejected request: {result.get('output', '')}")
                return json.loads(result["output"])

    def status(self, target, evidence=None):
        args = {"issue_identifier": self.trace.issue, "status": target}
        if evidence is not None:
            args["evidence"] = evidence
        self.tool("set_project_status", args)

    def evidence(self):
        validate_checkout(self.cwd, self.manifest["baseline_tree"])
        sha = git(self.cwd, "rev-parse", "HEAD")
        return {"acceptance": [{"id": "A1", "sha": sha, "result": "passed",
            "details": "Clean checkout and tracked tree matches baseline " + self.manifest["baseline_tree"]}],
            "validation": {"sha": sha, "result": "passed",
            "command": 'test -z "$(git status --porcelain)" && test "$(git rev-parse HEAD^{tree})" = '
                       + self.manifest["baseline_tree"]}}

    def workpad(self, objective):
        self.tool("agent_workpad", {"body": "## Agent Workpad\nObjective: " + objective +
            "\nAcceptance: tracked tree unchanged; normal lifecycle completed" +
            "\nCurrent: " + self.trace.role + "\nRelevant: thread " + self.thread +
            "\nValidation: unchanged baseline tree " + self.manifest["baseline_tree"] +
            "\nBlockers: none"})

    def checkout(self, branch, base):
        local = subprocess.run(["git", "-C", self.cwd, "show-ref", "--verify", "--quiet", "refs/heads/" + branch])
        remote = subprocess.run(["git", "-C", self.cwd, "show-ref", "--verify", "--quiet", "refs/remotes/origin/" + branch])
        if local.returncode == 0:
            git(self.cwd, "switch", branch)
        elif remote.returncode == 0:
            git(self.cwd, "switch", "-c", branch, "origin/" + branch)
        else:
            git(self.cwd, "switch", "-c", branch, "origin/" + base)

    def execute(self):
        issue = next(value for value in self.manifest["issues"].values()
                     if f'GH-{value["number"]}' == self.trace.issue)
        role = self.trace.role
        feature = issue["kind"] == "feature"
        branch = ("feature/" if feature else "task/") + self.trace.issue
        target = "main" if feature else "feature/GH-" + str(self.manifest["issues"][issue["parent"]]["number"])
        self.tool("agent_workpad", {})
        git(self.cwd, "fetch", "origin", "--prune")
        self.workpad("No-op " + issue["key"])
        if role in ("Ready", "In progress"):
            self.checkout(branch, target)
            if feature:
                git(self.cwd, "merge", "--ff-only", "origin/" + branch) if role != "Ready" else None
                self.evidence()
                git(self.cwd, "push", "origin", f"HEAD:refs/heads/{branch}")
                self.status("In progress" if role == "Ready" else "In review")
            else:
                if role == "Ready":
                    self.status("In progress")
                subject = "Symphony no-op " + self.trace.issue
                if subject not in git(self.cwd, "log", "--format=%s", "origin/" + target + "..HEAD"):
                    validate_checkout(self.cwd, self.manifest["baseline_tree"])
                    git(self.cwd, "-c", "user.name=Symphony E2E", "-c", "user.email=e2e@example.invalid",
                        "commit", "--allow-empty", "-m", subject)
                self.evidence()
                git(self.cwd, "push", "origin", f"HEAD:refs/heads/{branch}")
                self.status("In review")
        elif role == "In review":
            git(self.cwd, "switch", "--detach", "origin/" + branch)
            evidence = self.evidence()
            self.status("Human Review" if feature else "Integrating", evidence)
        elif role == "Integrating":
            pad = self.tool("agent_workpad", {})
            record = next(json.loads(line[8:]) for line in pad["body"].splitlines() if line.startswith("Review: "))
            require(git(self.cwd, "rev-parse", "origin/" + branch) == record["sha"], "Reviewed source moved")
            git(self.cwd, "switch", "--detach", "origin/" + target)
            git(self.cwd, "-c", "user.name=Symphony E2E", "-c", "user.email=e2e@example.invalid",
                "merge", "--no-ff", "--no-edit", record["sha"])
            evidence = self.evidence()
            git(self.cwd, "push", "origin", f"HEAD:refs/heads/{target}")
            self.status("Done", evidence)
        else:
            raise RuntimeError("Dispatched inactive status " + role)

    def run(self):
        while True:
            packet = self.read()
            method, identity = packet.get("method"), packet.get("id")
            if method == "initialize":
                self.send({"id": identity, "result": {}})
            elif method == "model/list":
                selections = self.manifest.get("model_routing", {})
                choices = [selections[role] for role in ("implementation", "review", "parent_review", "integration") if role in selections]
                choices += list(selections.get("issues", {}).values())
                models = {}
                for choice in choices:
                    model = models.setdefault(choice["model"], {"model": choice["model"], "defaultReasoningEffort": choice["effort"], "supportedReasoningEfforts": []})
                    effort = {"reasoningEffort": choice["effort"]}
                    if effort not in model["supportedReasoningEfforts"]:
                        model["supportedReasoningEfforts"].append(effort)
                self.send({"id": identity, "result": {"data": list(models.values()), "nextCursor": None}})
            elif method == "thread/start":
                self.cwd = packet["params"]["cwd"]
                self.send({"id": identity, "result": {"thread": {"id": self.thread}, "model": packet["params"].get("model")}})
            elif method == "turn/start":
                self.turn = uuid.uuid4().hex
                self.send({"id": identity, "result": {"turn": {"id": self.turn}}})
                try:
                    self.execute()
                    turn = {"id": self.turn, "status": "completed"}
                except Exception as error:
                    self.trace.emit("worker_error", message=str(error))
                    turn = {"id": self.turn, "status": "failed", "error": {"message": str(error)}}
                self.send({"method": "turn/completed", "params": {"threadId": self.thread, "turn": turn}})


def proxy(trace):
    """Capture only role metadata and status-tool receipts, never prompts or credentials."""
    command = ["bash", "-lc", "exec codex --config shell_environment_policy.inherit=all "
               "--config approvals_reviewer=auto_review app-server"]
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=sys.stderr, text=True, bufsize=1)

    def forward_input():
        try:
            for line in sys.stdin:
                trace.observe("symphony", json.loads(line))
                child.stdin.write(line)
                child.stdin.flush()
        finally:
            child.stdin.close()

    threading.Thread(target=forward_input, daemon=True).start()
    try:
        for line in child.stdout:
            try:
                trace.observe("worker", json.loads(line))
            except json.JSONDecodeError:
                pass
            sys.stdout.write(line)
            sys.stdout.flush()
    finally:
        if child.poll() is None:
            child.terminate()
        child.wait(timeout=15)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--mode", choices=["scripted", "codex"], required=True)
    args = parser.parse_args()
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    trace = Trace(Path(args.manifest).parent / "events")
    if args.mode == "scripted":
        ScriptedWorker(manifest, trace).run()
    else:
        proxy(trace)

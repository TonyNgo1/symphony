"""Portable support for the opt-in GitHub no-op acceptance harness (stdlib only)."""
import json
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

STATES = ["Backlog", "Ready", "In progress", "In review", "Integrating", "Human Review", "Done"]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def git(cwd, *args):
    result = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, timeout=90)
    require(result.returncode == 0, f"git {args[0]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def validate_checkout(cwd, baseline):
    require(not git(cwd, "status", "--porcelain"), "No-op workspace contains file changes")
    require(git(cwd, "rev-parse", "HEAD^{tree}") == baseline, "No-op commit changed the tracked tree")


def read_with_retry(reader, timeout=60, clock=time.monotonic, sleep=time.sleep):
    """A busy scheduler can temporarily time out snapshots; never retry mutations."""
    deadline = clock() + timeout
    while True:
        try:
            return reader()
        except (OSError, ValueError):
            if clock() >= deadline:
                raise
            sleep(1)


class Trace:
    def __init__(self, directory):
        Path(directory).mkdir(parents=True, exist_ok=True)
        self.path = Path(directory) / (uuid.uuid4().hex + ".jsonl")
        self.issue = None
        self.role = None
        self.thread = None
        self.calls = {}
        self.thread_model = None

    def emit(self, kind, **data):
        entry = dict(time=time.time(), kind=kind, issue=self.issue, role=self.role, thread=self.thread, **data)
        with self.path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(entry) + "\n")

    def observe(self, direction, packet):
        if not isinstance(packet, dict):
            return
        params = packet.get("params") or {}
        method = packet.get("method")
        if direction == "worker" and isinstance(packet.get("result"), dict) and "thread" in packet["result"]:
            self.thread = packet["result"]["thread"]["id"]
        if direction == "symphony" and method == "turn/start":
            text = "\n".join(item.get("text", "") for item in params.get("input", []))
            issue = re.search(r"Harness issue: (GH-\d+)", text)
            role = re.search(r"Harness role: ([^\r\n]+)", text)
            if issue:
                self.issue, self.role = issue[1], role[1]
            self.emit("turn_start", cwd=params.get("cwd"), model=params.get("model"), effort=params.get("effort"), thread_model=self.thread_model)
        if direction == "symphony" and method == "thread/start":
            self.thread_model = params.get("model")
        if direction == "worker" and method == "item/tool/call":
            args = params.get("arguments") or {}
            if not isinstance(args, dict):
                return
            if params.get("tool", params.get("name")) == "set_project_status":
                self.calls[packet["id"]] = args
                self.emit("status_requested", target=args.get("status"))
        if direction == "symphony" and packet.get("id") in self.calls:
            args = self.calls.pop(packet["id"])
            self.emit("status_result", target=args.get("status"),
                      success=packet.get("result", {}).get("success") is True,
                      evidence=args.get("evidence"))


def read_events(directory):
    events = []
    for path in Path(directory).glob("*.jsonl"):
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # A worker may currently be writing its final line.
    return sorted(events, key=lambda event: event["time"])


class GitHub:
    def __init__(self, token):
        require(bool(token), "GITHUB_TOKEN is required")
        self.token = token

    def request(self, method, path, body=None):
        require(path.startswith("/") and "://" not in path, "Expected a relative GitHub API path")
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request("https://api.github.com" + path, data=data, method=method,
            headers={"Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "symphony-noop-e2e",
                     "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                payload = response.read()
                return (json.loads(payload) if payload else None), response.headers
        except urllib.error.HTTPError as error:
            # Never log headers, token, or potentially sensitive API response bodies.
            if error.code == 403 and error.headers.get("X-RateLimit-Remaining") == "0":
                reset = error.headers.get("X-RateLimit-Reset", "")
                when = datetime.fromtimestamp(int(reset), timezone.utc).isoformat() if reset.isdigit() else "unknown"
                raise RuntimeError(f"GitHub REST rate limit exhausted; resets at {when}. "
                                   "Stop other pollers and wait before retrying or cleaning up.") from None
            raise RuntimeError(f"GitHub {method} {path} returned HTTP {error.code}") from None

    def call(self, method, path, body=None):
        return self.request(method, path, body)[0]

    def pages(self, path):
        result, seen = [], set()
        while path:
            require(path not in seen, "Repeated pagination cursor")
            seen.add(path)
            payload, headers = self.request("GET", path)
            require(isinstance(payload, list), "Expected a GitHub list response")
            result.extend(payload)
            match = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link", ""))
            if not match:
                break
            url = urllib.parse.urlsplit(match[1])
            require(url.scheme == "https" and url.netloc == "api.github.com", "Unexpected pagination host")
            path = url.path + ("?" + url.query if url.query else "")
        return result

    def graphql(self, query, variables):
        result = self.call("POST", "/graphql", {"query": query, "variables": variables})
        require(not result.get("errors"), "GitHub GraphQL operation failed; check project permissions")
        return result["data"]


def raw_name(value):
    return value.get("raw") if isinstance(value, dict) else value


def field_status(item, field):
    value = next((f.get("value") for f in item.get("fields", []) if f["id"] == field["id"]), None)
    option_id = value.get("id") if isinstance(value, dict) else value
    for option in field["options"]:
        if option["id"] == option_id:
            return raw_name(option["name"])
    return raw_name(value.get("name", value) if isinstance(value, dict) else value)


def assert_trace(manifest, events, approvals):
    """Require evidence for every role and ordering; never pass on final card colors alone."""
    issues = manifest["issues"]
    completed = {}
    for key, issue in issues.items():
        identity = f'GH-{issue["number"]}'
        own = [e for e in events if e["issue"] == identity]
        starts = [e for e in own if e["kind"] == "turn_start"]
        if manifest.get("model_routing"):
            config = manifest["model_routing"]
            for event in starts:
                role = "review" if event["role"] == "In review" else "integration" if event["role"] == "Integrating" else "implementation"
                expected = config[role]
                if role == "review" and issue["kind"] == "feature":
                    expected = config.get("parent_review", expected)
                if role == "implementation":
                    expected = config.get("issues", {}).get(key, expected)
                require(event.get("model") == expected["model"] and event.get("thread_model") == expected["model"]
                        and event.get("effort") == expected["effort"], f"{key}: incorrect {role} model routing")
        workspaces = {e.get("cwd") for e in starts}
        require(None not in workspaces and len(workspaces) == 1, f"{key}: worker roles did not reuse one workspace")
        phases = {e["role"] for e in starts}
        require(phases <= {"Ready", "In progress", "In review", "Integrating"}, f"{key}: dispatched an inactive state")
        require({"Ready", "In review", "Integrating"} <= phases, f"{key}: missing role evidence: {phases}")
        implementers = {e["thread"] for e in starts if e["role"] in ("Ready", "In progress")}
        reviewers = {e["thread"] for e in starts if e["role"] == "In review"}
        integrators = {e["thread"] for e in starts if e["role"] == "Integrating"}
        require(None not in implementers | reviewers | integrators, f"{key}: missing thread ID")
        require(not implementers & reviewers and not reviewers & integrators, f"{key}: reused a role's thread")
        successes = [e for e in own if e["kind"] == "status_result" and e["success"]]
        for target in ("In progress", "In review", "Done"):
            require(any(e["target"] == target for e in successes), f"{key}: missing successful {target} transition")
        completed[key] = min(e["time"] for e in successes if e["target"] == "Done")
        approved_target = "Human Review" if issue["kind"] == "feature" else "Integrating"
        require(any(e["target"] == approved_target and e["role"] == "In review" and e.get("evidence")
                    for e in successes), f"{key}: no evidence-bearing fresh review")
        if issue["kind"] == "feature":
            require(key in approvals, f"{key}: human pause was not verified")
            require(all(e["time"] >= approvals[key] for e in starts if e["role"] == "Integrating"),
                    f"{key}: integrated before controller approval")
            paused_at = min(e["time"] for e in successes if e["target"] == "Human Review")
            require(not any(paused_at < e["time"] < approvals[key] for e in starts),
                    f"{key}: dispatched during Human Review pause")
    for key, issue in issues.items():
        starts = [e for e in events if e["kind"] == "turn_start" and e["issue"] == f'GH-{issue["number"]}']
        if issue["parent"]:
            parent_identity = f'GH-{issues[issue["parent"]]["number"]}'
            bootstrap = min(e["time"] for e in events if e["kind"] == "status_result"
                            and e["issue"] == parent_identity and e["success"] and e["target"] == "In progress")
            require(min(e["time"] for e in starts) >= bootstrap, f"{key}: dispatched before parent bootstrap")
        for blocker in issue["blockers"]:
            require(min(e["time"] for e in starts) >= completed[blocker], f"{key}: dispatched before {blocker} Done")
        if issue["kind"] == "feature":
            review_start = min(e["time"] for e in starts if e["role"] == "In review")
            for child, child_issue in issues.items():
                if child_issue["parent"] == key:
                    require(review_start >= completed[child], f"{key}: reviewed before child {child} Done")

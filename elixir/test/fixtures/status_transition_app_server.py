"""Offline peer that records the tool reply before allowing the turn to finish."""
import json
from pathlib import Path
import sys
import time

root, target = Path(sys.argv[1]), sys.argv[2]

def send(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    packet = json.loads(line)
    method, identity = packet.get("method"), packet.get("id")
    if method == "initialize":
        send({"id": identity, "result": {}})
    elif method == "thread/start":
        send({"id": identity, "result": {"thread": {"id": "handoff"}}})
    elif method == "turn/start":
        send({"id": identity, "result": {"turn": {"id": "turn"}}})
        send({"id": "status", "method": "item/tool/call", "params": {
            "tool": "set_project_status", "arguments": {"issue_identifier": "GH-2", "status": target}}})
    elif identity == "status":
        (root / "receipt.json").write_text(json.dumps(packet))
        deadline = time.monotonic() + 10
        while not (root / "finish-turn").exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("Test did not release turn")
            time.sleep(0.01)
        send({"method": "turn/completed", "params": {"turn": {"id": "turn", "status": "completed"}}})

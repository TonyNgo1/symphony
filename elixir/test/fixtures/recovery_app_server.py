"""Local peer for checkpoint/rotation tests; no model calls or network."""
import json
from pathlib import Path
import sys

root, mode = Path(sys.argv[1]), sys.argv[2]
count = 0

def send(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    packet = json.loads(line)
    with (root / "wire.jsonl").open("a") as stream:
        stream.write(line)
    method, identity = packet.get("method"), packet.get("id")
    if method == "initialize":
        send({"id": identity, "result": {}})
    elif method == "thread/start":
        send({"id": identity, "result": {"thread": {"id": "recovery-thread"}}})
    elif method == "turn/start":
        count += 1
        send({"id": identity, "result": {"turn": {"id": str(count)}}})
        if mode == "quota":
            send({"method": "turn/failed", "params": {"error": {"code": "usage_limit_exceeded"}}})
        elif mode == "input":
            send({"method": "turn/input_required", "params": {"message": "Need creative direction"}})
        elif mode == "checkpoint" and count > 1:
            send({"id": "pad", "method": "item/tool/call", "params": {"tool": "agent_workpad", "arguments": {
                "body": "## Agent Workpad\nObjective: test\nDone: investigation\nNext: implement the test\nValidation: not run\nBlockers: none"}}})
        else:
            send({"method": "turn/completed", "params": {"turn": {"id": str(count), "status": "completed"}}})
    elif identity == "pad":
        send({"method": "turn/completed", "params": {"turn": {"id": str(count), "status": "completed"}}})

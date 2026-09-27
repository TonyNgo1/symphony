"""Offline app-server peer: paginated catalog and captured wire requests, no API calls."""
import json
from pathlib import Path
import sys
import uuid

thread = str(uuid.uuid4())
log = Path(sys.argv[1]) / (thread + ".jsonl")

def send(packet):
    print(json.dumps(packet), flush=True)

for line in sys.stdin:
    packet = json.loads(line)
    with log.open("a") as stream:
        stream.write(line)
    method, identity = packet.get("method"), packet.get("id")
    params = packet.get("params", {})
    if method == "initialize":
        send({"id": identity, "result": {}})
    elif method == "model/list":
        models = [{"model": name, "isDefault": name == "standard", "defaultReasoningEffort": "medium",
                   "supportedReasoningEfforts": [{"reasoningEffort": effort} for effort in ["low", "medium", "high"]]}
                  for name in ["small", "standard", "reviewer", "integrator"]]
        if "--with-astra" in sys.argv:
            models.append({"model": "gpt-6-astra", "isDefault": False, "defaultReasoningEffort": "medium",
                           "supportedReasoningEfforts": [{"reasoningEffort": "high"}]})
        second = params.get("cursor") == "page-2"
        send({"id": identity, "result": {"data": models[1:] if second else models[:1], "nextCursor": None if second else "page-2"}})
    elif method == "thread/start":
        model = "wrong-model" if "--wrong-model" in sys.argv else params.get("model")
        project = "wrong-project" if "--wrong-project" in sys.argv else params.get("projectId")
        payload = {"id": thread, "projectId": project}
        if "--missing-project" in sys.argv:
            payload.pop("projectId")
        send({"id": identity, "result": {"thread": payload, "model": model}})
    elif method == "turn/start":
        send({"id": identity, "result": {"turn": {"id": "turn"}}})
        send({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "turn", "status": "completed"}}})

import json
import sys


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        print(json.dumps({"id": message["id"], "result": {"userAgent": "fake"}}), flush=True)
    elif method == "thread/start":
        print(json.dumps({"id": message["id"], "result": {"thread": {"id": "thread-test"}}}), flush=True)
    elif method == "turn/start":
        print(json.dumps({"id": message["id"], "result": {"turn": {"id": "turn-test"}}}), flush=True)
        print(json.dumps({
            "method": "thread/tokenUsage/updated",
            "params": {
                "threadId": "thread-test",
                "turnId": "turn-test",
                "tokenUsage": {"total": {"inputTokens": 3, "outputTokens": 2, "totalTokens": 5}},
            },
        }), flush=True)
        print(json.dumps({
            "method": "turn/completed",
            "params": {"turn": {"id": "turn-test", "status": "completed"}},
        }), flush=True)


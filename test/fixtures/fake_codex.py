import json
import os
from pathlib import Path
import signal
import sys
import time


mode = sys.argv[1] if len(sys.argv) > 1 else "complete"
argument = sys.argv[2] if len(sys.argv) > 2 else ""
signal.signal(signal.SIGPIPE, signal.SIG_DFL)


def emit(message):
    print(json.dumps(message), flush=True)


try:
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            if mode == "startup-noise":
                while True:
                    emit({"method": "probe/noise", "params": {}})
                    time.sleep(0.04)
            if mode == "check-secret" and os.getenv(argument) is not None:
                emit({"id": message["id"], "error": {"message": "secret leaked"}})
            else:
                emit({"id": message["id"], "result": {"userAgent": "fake"}})
        elif method == "thread/start":
            emit({"id": message["id"], "result": {"thread": {"id": "thread-test"}}})
        elif method == "turn/start":
            emit({"id": message["id"], "result": {"turn": {"id": "turn-test"}}})
            if mode == "permission":
                emit({"id": 99, "method": "item/permissions/requestApproval", "params": {}})
                Path(argument).write_text(sys.stdin.readline())
            elif mode in ("command-approval", "file-approval"):
                method = {
                    "command-approval": "item/commandExecution/requestApproval",
                    "file-approval": "item/fileChange/requestApproval",
                }[mode]
                emit({"id": 98, "method": method, "params": {}})
                Path(argument).write_text(sys.stdin.readline())
                emit({"method": "turn/completed", "params": {"turn": {"id": "turn-test", "status": "completed"}}})
            elif mode == "user-input":
                emit({"id": 100, "method": "item/tool/requestUserInput", "params": {}})
                Path(argument).write_text(sys.stdin.readline())
            elif mode == "unsupported-tool":
                emit({"id": 101, "method": "item/tool/call", "params": {}})
                Path(argument).write_text(sys.stdin.readline())
                emit({"method": "turn/completed", "params": {"turn": {"id": "turn-test", "status": "completed"}}})
            elif mode == "hang":
                Path(argument).write_text("started")
                while True:
                    emit({"method": "probe/tick", "params": {}})
                    time.sleep(0.1)
            elif mode == "turn-silent":
                while True:
                    time.sleep(1)
            elif mode == "turn-exit":
                sys.exit(3)
            elif mode == "record":
                prompt = message["params"]["input"][0]["text"]
                with Path(argument).open("a") as output:
                    output.write(prompt + "\n")
                emit({"method": "turn/completed", "params": {"turn": {"id": "turn-test", "status": "completed"}}})
            else:
                emit({
                    "method": "thread/tokenUsage/updated",
                    "params": {
                        "threadId": "thread-test",
                        "turnId": "turn-test",
                        "tokenUsage": {"total": {"inputTokens": 3, "outputTokens": 2, "totalTokens": 5}},
                    },
                })
                emit({"method": "turn/completed", "params": {"turn": {"id": "turn-test", "status": "completed"}}})
except BrokenPipeError:
    pass

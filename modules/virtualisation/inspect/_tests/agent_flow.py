"""Uses the agent in a guest through guest-agent the way the tools above it will: a program run, a file written and read back."""
import base64
import json
import subprocess
import sys
import time


def ask(name, arguments=None):
    command = ["guest-agent", name] + ([json.dumps(arguments)] if arguments is not None else [])
    done = subprocess.run(command, check=False, capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(f"{name}: {done.stderr.strip()}")
    return json.loads(done.stdout)["return"]


shell = sys.argv[1]
# The agent in the guest starts once its channel is there.
for _ in range(150):
    ping = subprocess.run(["guest-agent", "ping"], check=False, capture_output=True, text=True)
    if ping.returncode == 0:
        break
    time.sleep(0.2)
else:
    sys.exit(f"the agent never answered: {ping.stderr.strip()}")

pid = ask("exec", {"path": shell, "arg": ["-c", "echo run-by-the-agent; echo to-the-serial > /dev/ttyS0"], "capture-output": True})["pid"]
for _ in range(100):
    status = ask("exec-status", {"pid": pid})
    if status["exited"]:
        break
    time.sleep(0.1)
if status.get("exitcode") != 0 or base64.b64decode(status.get("out-data", "")) != b"run-by-the-agent\n":
    sys.exit(f"the program did not run as asked: {status}")

handle = ask("file-open", {"path": "/tmp/from-the-host", "mode": "w"})
ask("file-write", {"handle": handle, "buf-b64": base64.b64encode(b"written through the agent\n").decode()})
ask("file-close", {"handle": handle})
handle = ask("file-open", {"path": "/tmp/from-the-host", "mode": "r"})
read = ask("file-read", {"handle": handle, "count": 4096})
ask("file-close", {"handle": handle})
if base64.b64decode(read["buf-b64"]) != b"written through the agent\n":
    sys.exit(f"the file did not come back as written: {read}")
print("the agent ran a program and kept a file")

"""Stands in for a session whose guest runs a program that answers guest-mcp as badly as it can.

What such a program says is the guest's. guest-mcp has to pass on whole messages alone, with nothing in them that
steers a terminal, and say of the rest that it left it out.
"""
import base64
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading

ANSWERS = (b"no JSON here\n" + b"[" * 100000 + b"\n" + b'"a text is no message"\n'
           + json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"te\x1bxt": "fine\x1b[2J\x07 \u009b", "list": [1, "two\x00"]}}).encode() + b"\n")
ASKED = '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}'
started = []
# The programs the agent said had ended, which it then no longer knows.
ended = set()


def told(name, arguments):
    """The first program started begins the job and ends. Every later one is a look at what the job has answered from a place on, the fifth of its words."""
    if name == "guest-get-osinfo":
        return {"id": "linux", "name": "Fake"}
    if name == "guest-exec":
        started.append(arguments["arg"])
        return {"pid": len(started)}
    if name == "guest-file-open":
        return None
    if name == "guest-exec-status":
        if arguments["pid"] in ended:
            return None
        words = started[arguments["pid"] - 1]
        ended.add(arguments["pid"])
        if words is started[0]:
            return {"exited": True, "exitcode": 0, "out-data": "", "err-data": ""}
        place = int(words[4]) if len(words) > 4 and words[4].isdigit() else 0
        return {"exited": True, "exitcode": 0, "out-data": base64.b64encode(ANSWERS[place:]).decode()}
    return {}


def serve(server):
    while True:
        conn, _ = server.accept()
        with conn:
            line = b""
            while not line.endswith(b"\n"):
                more, descriptors, _, _ = socket.recv_fds(conn, 65536, 4)
                for descriptor in descriptors:
                    os.close(descriptor)
                if not more:
                    break
                line += more
            request = json.loads(line)
            given = told(request.get("execute"), request.get("arguments"))
            if given is None:
                conn.sendall(json.dumps({"error": "no such file"}).encode() + b"\n")
                continue
            answer = json.dumps({"return": given}).encode()
            carrier = os.memfd_create("answer")
            with os.fdopen(carrier, "wb", closefd=False) as f:
                f.write(answer)
            os.lseek(carrier, 0, os.SEEK_SET)
            socket.send_fds(conn, [json.dumps({"size": len(answer)}).encode() + b"\n"], [carrier])
            os.close(carrier)


folder = tempfile.mkdtemp()
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(os.path.join(folder, "control.sock"))
server.listen(8)
threading.Thread(target=serve, args=(server,), daemon=True).start()

talk = subprocess.Popen(["guest-mcp", "any-program"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={**os.environ, "VM_INSPECT_DIR": folder})
talk.stdin.write(ASKED.encode() + b"\n")
talk.stdin.flush()
answer = talk.stdout.readline()
talk.stdin.close()
rest, complaints = talk.communicate(timeout=60)
if json.loads(answer) != {"jsonrpc": "2.0", "id": 1, "result": {"text": "fine[2J ", "list": [1, "two"]}} or rest or max(answer) > 126 or complaints.count(b"no message") != 3:
    sys.exit(f"guest-mcp passed this on: {answer!r} {rest!r} {complaints!r}")
if b"Traceback" in complaints or not any(words[5:6] == [ASKED] for words in started):
    sys.exit(f"guest-mcp did not hand the line on as it came: {started} {complaints!r}")

done = subprocess.run(["guest-mcp"], capture_output=True, check=False, env={**os.environ, "VM_INSPECT_DIR": folder})
if done.returncode != 1 or not done.stderr.startswith(b"guest-mcp: the program to talk to is missing"):
    sys.exit(f"guest-mcp without a program said: {done.stderr!r}")

print("guest-mcp was not led astray")

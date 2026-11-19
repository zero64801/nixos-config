"""Asks an open session for a transfer's disk by hand: what it refuses, and that a file the guest is to read stays as it was."""
import hashlib
import json
import os
import socket
import subprocess
import sys

# The guest's name for the disk, once it has seen it.
FOUND = """n=0
until found=$(grep -ls vm-inspect-data /sys/block/sd*/device/vpd_pg80) || [ "$n" -ge 50 ]; do sleep 0.2; n=$((n + 1)); done
dev=/dev/$(echo "$found" | cut -d/ -f4)
"""


def ask(request, carrying=()):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.connect(os.path.join(os.environ["VM_INSPECT_DIR"], "control.sock"))
    with conn:
        if carrying:
            socket.send_fds(conn, [json.dumps(request).encode() + b"\n"], list(carrying))
        else:
            conn.sendall(json.dumps(request).encode() + b"\n")
        return json.loads(conn.makefile().readline())


def digest(path):
    with open(path, "rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def refused(request, carrying, reason):
    reply = ask(request, carrying)
    if reason not in reply.get("error", ""):
        sys.exit(f"{request} was answered with {reply}, where it should be refused: {reason}")


kept = "/tmp/kept"
with open(kept, "wb") as f:
    f.write(b"kept as it was\n" * 4096)
before = digest(kept)

refused({"do": "disk", "write": False}, (), "the one file it is made of")
reading, writing = os.pipe()
refused({"do": "disk", "write": False}, [reading], "a plain file that is not empty")
with open("/tmp/empty", "wb") as f:
    refused({"do": "disk", "write": False}, [f.fileno()], "a plain file that is not empty")
with open(kept, "rb") as f:
    refused({"do": "disk", "write": True}, [f.fileno()], "opened for writing")
    reply = ask({"do": "disk", "write": False}, [f.fileno()])
    if reply:
        sys.exit(f"the disk was not plugged in: {reply}")
tried = subprocess.run(["guest-exec", "--shell", FOUND + 'echo ro=$(cat /sys/block/${dev##*/}/ro); dd if=/dev/zero of="$dev" bs=512 count=1 conv=fsync; echo wrote=$?'],
                       check=False, capture_output=True, text=True)
if "ro=1" not in tried.stdout or "wrote=1" not in tried.stdout:
    sys.exit(f"the guest could write a disk it was only to read: {tried.stdout} {tried.stderr}")
if digest(kept) != before:
    sys.exit("the file behind the disk changed")
# The disk stays in, for the session to take along when it ends.
print("the disk was refused where it should be and could only be read")

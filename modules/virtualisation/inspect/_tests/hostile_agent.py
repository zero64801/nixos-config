"""Stands in for a session whose guest answers as badly as it can, and checks that every tool stays within its bounds.

A guest decides what its agent says. Each case below is something a tool must end on in plain words, or get
through unharmed: no traceback, nothing that steers a terminal, nothing read or written past a limit.
"""
import base64
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading

MIB = 1024 * 1024
ESCAPE = b"\x1b"


def text(data):
    return base64.b64encode(data).decode()


HONEST = {
    "guest-ping": {},
    "guest-info": {"version": "1.0"},
    "guest-get-osinfo": {"id": "linux", "name": "Fake"},
    "guest-get-host-name": {"host-name": "fake"},
    "guest-get-users": [],
    "guest-get-time": 0,
    "guest-get-fsinfo": [],
    "guest-exec": {"pid": 7},
    "guest-exec-status": {"exited": True, "exitcode": 0, "out-data": "", "err-data": ""},
    "guest-file-open": 5,
    "guest-file-close": {},
    "guest-file-seek": {"position": 100, "eof": False},
    "guest-file-read": {"count": 3, "buf-b64": text(b"abc"), "eof": True},
}
# What the guest says in the case that is running: an answer for a command, or the bytes to send as they are.
case = {}
# What each command was last asked with.
asked = {}
ended = set()


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
            name = request.get("execute")
            asked[name] = request.get("arguments")
            told = case.get(name, HONEST.get(name, {}))
            # As the agent does, a program it said had ended is no longer known, until a new one gets its number.
            pid = (request.get("arguments") or {}).get("pid")
            if name == "guest-exec":
                ended.clear()
            elif name == "guest-exec-status" and "keep-ending" not in case:
                if pid in ended:
                    conn.sendall(json.dumps({"error": f"PID {pid} does not exist"}).encode() + b"\n")
                    continue
                if isinstance(told, dict) and told.get("exited") is True:
                    ended.add(pid)
            answer = told if isinstance(told, bytes) else json.dumps({"return": told}).encode()
            if case.get("bare"):
                conn.sendall(json.dumps({"size": len(answer)}).encode() + b"\n")
                continue
            carrier = os.memfd_create("answer")
            with os.fdopen(carrier, "wb", closefd=False) as f:
                f.write(answer)
            os.lseek(carrier, 0, os.SEEK_SET)
            socket.send_fds(conn, [json.dumps({"size": len(answer) + case.get("off", 0)}).encode() + b"\n"], [carrier])
            os.close(carrier)


def tool(*words, **told):
    case.clear()
    case.update({name.replace("_", "-"): value for name, value in told.items()})
    done = subprocess.run(words, check=False, capture_output=True, timeout=120, env={**os.environ, "VM_INSPECT_DIR": folder})
    if b"Traceback" in done.stderr or ESCAPE in done.stdout + done.stderr:
        sys.exit(f"{words} fell over or let an escape through: {done.stdout!r} {done.stderr!r}")
    return done


def refused(done, reason):
    if done.returncode == 0 or reason.encode() not in done.stderr:
        sys.exit(f"{done.args} should have ended on: {reason}. It said: {done.stdout!r} {done.stderr!r}")


folder = tempfile.mkdtemp()
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(os.path.join(folder, "control.sock"))
server.listen(8)
threading.Thread(target=serve, args=(server,), daemon=True).start()
pulled = os.path.join(folder, "pulled")

refused(tool("guest-exec", "true", guest_exec=b"\x00\xff no JSON at all"), "is not JSON")
refused(tool("guest-exec", "true", guest_exec=b"[" * 200000), "is not JSON")
refused(tool("guest-exec", "true", guest_exec={"pid": "7"}), "does not have the shape")
refused(tool("guest-exec", "true", guest_exec=["a", "list"]), "does not have the shape")
refused(tool("guest-exec", "true", guest_exec_status={"exited": "yes"}), "does not have the shape")
refused(tool("guest-exec", "true", guest_exec_status={"exited": True, "exitcode": 0, "out-data": "!!! no base64 !!!"}), "does not have the shape")
refused(tool("guest-exec", "true", off=5), "is not the size it said")
refused(tool("guest-exec", "true", bare=True), "came without what it should carry")
refused(tool("guest-status", "--json", guest_ping=b"x" * (16 * MIB + 10)), "is not the size it said")
refused(tool("guest-exec", "--timeout", "1", "true", guest_exec_status={"exited": False}), "still running after 1 seconds")
refused(tool("guest-exec", "true", keep_ending=True), "keeps answering that program 7 ended")

done = tool("guest-exec", "true", guest_exec_status={"exited": True, "exitcode": 3, "out-data": text(b"a\x1b[31mb\x07\xc2\x9b2J\n"), "err-data": text(b"\x1b]0;title\x07")})
if done.returncode != 3 or done.stdout != b"a[31mb2J\n":
    sys.exit(f"what a program printed came through as {done.stdout!r} with status {done.returncode}")

done = tool("guest-status", guest_get_host_name={"host-name": "n" * 100000 + "\x1b[2J"}, guest_get_users=[{"user": {"not": "a name"}}, "nor this"])
if done.returncode != 0 or b"name: nnnn" not in done.stdout or len(done.stdout) > 4000:
    sys.exit(f"guest-status printed {len(done.stdout)} bytes of what the guest called itself: {done.stderr!r}")

# A file that never ends, from a guest that said it was small.
endless = {"count": MIB, "buf-b64": text(b"e" * MIB), "eof": False}
done = tool("guest-read", "--max", "2M", "/endless", guest_file_read=endless)
if done.returncode != 0 or len(done.stdout) != 2 * MIB or b"the file goes on" not in done.stderr:
    sys.exit(f"guest-read took {len(done.stdout)} bytes of an endless file: {done.stderr!r}")
refused(tool("guest-pull", "--max", "3M", "/endless", pulled, guest_file_read=endless), "grew past what is allowed")
if os.path.getsize(pulled) > 3 * MIB:
    sys.exit(f"guest-pull wrote {os.path.getsize(pulled)} bytes where 3 MiB were allowed")
refused(tool("guest-pull", "/small", pulled, guest_exec_status={"exited": True, "exitcode": 0, "out-data": text(b"0" * 64 + b"\n")}), "is not what the guest says")
refused(tool("guest-pull", "/huge", pulled, guest_file_seek={"position": 2 ** 62, "eof": False}), "more than the")
refused(tool("guest-pull", "/odd", pulled, guest_file_seek={"position": -5}), "could not hash")

# A name the guest gives for who is logged in goes into a shell's line, where it must stay one word.
done = tool("guest-exec", "--as-user", "true", guest_get_users=[{"user": "x; touch /tmp/owned #"}], guest_exec={"pid": "show the line"})
refused(done, "does not have the shape")
if "su -s /bin/sh 'x; touch /tmp/owned #' -c " not in asked["guest-exec"]["arg"][1]:
    sys.exit(f"a name from the guest went into a shell's line like this: {asked['guest-exec']}")

windows = "screen\t100\t100\nnot\ta\twindow\n1\t2\tprog\t0\t0\t10\t10\tfront\ttitle\x1b[2J\n9\t9\tp\tNaN\t0\t1\t1\t-\tbad\n" + "5\t5\tp\t0\t0\t1\t1\t-\tmany\n" * 5000
done = tool("guest-windows", guest_get_osinfo={"id": "mswindows"}, guest_exec_status={"exited": True, "exitcode": 0, "out-data": text(windows.encode())})
if done.returncode != 0 or b"0x1  pid 2  prog  0,0 10x10  front  title[2J" not in done.stdout or b"bad" in done.stdout or done.stdout.count(b"\n") > 302:
    sys.exit(f"guest-windows made this of a hostile listing: {done.stdout[:600]!r} {done.stderr!r}")

# A window's picture comes from the guest as plain rows, which have to be as many as their header says.
osinfo, shot = {"id": "mswindows"}, os.path.join(folder, "window.png")
for lie in [b"no picture at all", b"VMSHOT\0\0" + (16384).to_bytes(4, "little") * 2 + b"\0" * 30, b"VMSHOT\0\0" + (2).to_bytes(4, "little") + (1).to_bytes(4, "little") + b"\0" * 5]:
    refused(tool("guest-shot", "--window", "any", shot, guest_get_osinfo=osinfo, guest_file_read={"count": len(lie), "buf-b64": text(lie), "eof": True}), "is not one")
real = b"VMSHOT\0\0" + (2).to_bytes(4, "little") + (1).to_bytes(4, "little") + bytes([1, 2, 3, 4, 5, 6])
done = tool("guest-shot", "--window", "any", shot, guest_get_osinfo=osinfo, guest_file_read={"count": len(real), "buf-b64": text(real), "eof": True},
            guest_exec_status={"exited": True, "exitcode": 0, "out-data": text(b"a title\x1b[2J\n")})
with open(shot, "rb") as f:
    made = f.read()
if done.returncode != 0 or not done.stdout.endswith(b" 2x1\n") or not made.startswith(b"\x89PNG") or b"a title[2J" not in done.stderr:
    sys.exit(f"guest-shot made this of a window's picture: {done.stdout!r} {done.stderr!r}")

print("no tool was led astray")

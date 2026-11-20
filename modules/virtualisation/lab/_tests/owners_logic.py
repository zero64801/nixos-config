"""How owners reads what the guest's own tools print, in Linux and in Windows, and which flow it puts each program to.
Started with the folder of guest-net's code."""
import sys

sys.path.insert(0, sys.argv[1])
import owners

WINDOWS = """
tcp 0.0.0.0:135 0.0.0.0:0 Listen 1048 svchost
tcp 192.168.122.48:58719 4.160.58.170:443 Established 4152 MsMpEng
tcp [::]:445 [::]:0 Listen 4 System
tcp [fe80::75ce:2ad2:8490:f638%7]:51000 [fe80::1%7]:443 TimeWait 0 Idle
tcp 192.168.122.48:58720 104.20.23.154:80 SynSent 7380 Microsoft Edge Update
udp 0.0.0.0:5353 * - 3360 msedge
udp [::]:123 * - 11820 svchost
guest-exec: exit 0, what follows was written by the guest
"""
found = owners.parse(WINDOWS)
assert [(e["proto"], e["local"], e["remote"], e["state"], e["pid"], e["process"]) for e in found] == [
    ("tcp", "0.0.0.0:135", "", "LISTENING", 1048, "svchost"),
    ("tcp", "192.168.122.48:58719", "4.160.58.170:443", "ESTABLISHED", 4152, "MsMpEng"),
    ("tcp", "[::]:445", "", "LISTENING", 4, "System"),
    ("tcp", "[fe80::75ce:2ad2:8490:f638]:51000", "[fe80::1]:443", "TIME_WAIT", 0, "Idle"),
    ("tcp", "192.168.122.48:58720", "104.20.23.154:80", "SYN_SENT", 7380, "Microsoft Edge Update"),
    ("udp", "0.0.0.0:5353", "", "", 3360, "msedge"),
    ("udp", "[::]:123", "", "", 11820, "svchost"),
], found

LINUX = """
tcp   ESTAB  0      0      10.9.9.50:40312     10.9.9.1:9000      users:(("nc",pid=812,fd=3))
udp   UNCONN 0      0      0.0.0.0:68          0.0.0.0:*          users:(("dhcpcd",pid=301,fd=6))
tcp        0      0 10.9.9.50:40314         10.9.9.1:8000           ESTABLISHED 813/wget
tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN      200/sshd
"""
found = owners.parse(LINUX)
assert [(e["proto"], e["local"], e["remote"], e["state"], e["pid"], e["process"]) for e in found] == [
    ("tcp", "10.9.9.50:40312", "10.9.9.1:9000", "ESTAB", 812, "nc"),
    ("udp", "0.0.0.0:68", "", "UNCONN", 301, "dhcpcd"),
    ("tcp", "10.9.9.50:40314", "10.9.9.1:8000", "ESTABLISHED", 813, "wget"),
    ("tcp", "0.0.0.0:22", "", "LISTEN", 200, "sshd"),
], found

assert owners.parse("tcp 1.2.3.4:5 6.7.8.9:10 Established 12 \x1b]0;steer\x07name")[0]["process"] == "?]0;steer?name"

PROCESSES = """
process 1 (systemd) S 0 1 1 0 -1 4194560
process 812 (nc) S 790 812 790 0 -1 4194304
process 813 (a (strange) name) R 812 813 790 0 -1 4194304
process 4152 708 MsMpEng.exe
process 7380 1 Microsoft Edge Update.exe
process 99999999999 1 too large.exe
tcp        0      0 10.9.9.50:40314         10.9.9.1:8000           ESTABLISHED 813/wget
"""
assert [(p["pid"], p["ppid"], p["process"]) for p in owners.parse_processes(PROCESSES)] == [
    (1, 0, "systemd"), (812, 790, "nc"), (813, 812, "a (strange) name"), (4152, 708, "MsMpEng.exe"), (7380, 1, "Microsoft Edge Update.exe"),
], owners.parse_processes(PROCESSES)
assert owners.parse_processes("process 5 (\x1b[2J) S 1 5")[0]["process"] == "?[2J"


class Memory:
    """Processes as MemProcFS gives them: a program, the shell that started it and the service that started the shell."""
    def __init__(self):
        self.table = {30: ("curl.exe", 20), 20: ("cmd.exe", 10), 10: ("services.exe", 4)}

    def information(self, pid):
        if pid not in self.table:
            raise LookupError(pid)
        return self.table[pid][0], self.table[pid][1], set()


assert [(p["pid"], p["ppid"], p["process"]) for p in owners.lineage(Memory(), [30, 20])] == [
    (30, 20, "curl.exe"), (20, 10, "cmd.exe"), (10, 4, "services.exe"),
], "every process up to the first that is gone, each once"

flow = {"proto": "tcp", "guest": "192.168.122.48:58719", "remote": "4.160.58.170:443", "ended": 100.0}
seen = [
    {"proto": "tcp", "local": "192.168.122.48:58719", "remote": "4.160.58.170:443", "pid": 1, "process": "old", "time": 10 * 10 ** 9},
    {"proto": "tcp", "local": "192.168.122.48:58719", "remote": "4.160.58.170:443", "pid": 2, "process": "new", "time": 90 * 10 ** 9},
    {"proto": "tcp", "local": "192.168.122.48:58719", "remote": "4.160.58.170:443", "pid": 3, "process": "later", "time": 200 * 10 ** 9},
    {"proto": "tcp", "local": "192.168.122.48:58719", "remote": "1.1.1.1:443", "pid": 4, "process": "other", "time": 95 * 10 ** 9},
]
assert owners.owner_of(seen, flow) == "new[2]", owners.owner_of(seen, flow)
print("owners reads Windows and Linux alike")

# A session of an older build refuses notes of processes, which only add to what readers can tell, so following keys or
# owners has to go on with one warning, while a refused note that is needed still stops.
import contextlib
import io
import json
import os
import socket
import tempfile
import threading

import capture

capture.SETTINGS = capture.Settings("net", "-", "-", "-", "-", "-", "-", "-")
folder = tempfile.mkdtemp()
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(os.path.join(folder, "control.sock"))
listener.listen()


def session():
    while True:
        conn, _ = listener.accept()
        with conn:
            request = json.loads(conn.makefile().readline())
            answer = {"folder": folder} if request.get("kind") == "keys" else {"error": "a note is of keys or owners"}
            conn.sendall(json.dumps(answer).encode() + b"\n")


threading.Thread(target=session, daemon=True).start()
os.environ["VM_INSPECT_DIR"] = folder
with contextlib.redirect_stderr(io.StringIO()) as said:
    for _ in range(3):
        assert capture.tell({"do": "note", "kind": "processes", "entries": []}, needed=False) is None
    assert capture.tell({"do": "note", "kind": "keys", "lines": []}) == {"folder": folder}
assert said.getvalue().count("keeps no processes") == 1, said.getvalue()
try:
    with contextlib.redirect_stderr(io.StringIO()):
        capture.tell({"do": "note", "kind": "owners", "entries": []})
    raise AssertionError("a needed note the session refused went by unseen")
except SystemExit:
    pass
print("a session that keeps no processes only warns, once")

udp = {"proto": "udp", "guest": "192.168.122.48:55157", "remote": "172.217.29.49:443", "ended": 100.0}
assert owners.owner_of([{"proto": "udp", "local": "0.0.0.0:55157", "remote": "", "pid": 7804, "process": "msedge.exe", "time": 90 * 10 ** 9},
                        {"proto": "udp", "local": "0.0.0.0:55158", "remote": "", "pid": 1, "process": "other", "time": 90 * 10 ** 9}],
                       udp) == "msedge.exe[7804]", "a UDP socket bound to every address has to be the flow's of its port"
print("a UDP socket bound to every address is its port's flows' owner")

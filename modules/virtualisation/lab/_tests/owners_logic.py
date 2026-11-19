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

flow = {"proto": "tcp", "guest": "192.168.122.48:58719", "remote": "4.160.58.170:443", "ended": 100.0}
seen = [
    {"proto": "tcp", "local": "192.168.122.48:58719", "remote": "4.160.58.170:443", "pid": 1, "process": "old", "time": 10 * 10 ** 9},
    {"proto": "tcp", "local": "192.168.122.48:58719", "remote": "4.160.58.170:443", "pid": 2, "process": "new", "time": 90 * 10 ** 9},
    {"proto": "tcp", "local": "192.168.122.48:58719", "remote": "4.160.58.170:443", "pid": 3, "process": "later", "time": 200 * 10 ** 9},
    {"proto": "tcp", "local": "192.168.122.48:58719", "remote": "1.1.1.1:443", "pid": 4, "process": "other", "time": 95 * 10 ** 9},
]
assert owners.owner_of(seen, flow) == "new[2]", owners.owner_of(seen, flow)
print("owners reads Windows and Linux alike")

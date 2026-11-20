"""Which program of the guest a connection belongs to, looked for while it lasts and kept in the capture, and which
program started which, for --children.

In a Windows guest the connections and processes are read from the guest's memory through MemProcFS, which the guest
does not see. Elsewhere the guest is asked through its agent, with ss or netstat and /proc, which it does see.
"""
import ctypes
import importlib.util
import ipaddress
import os
import re
import subprocess
import sys
import time

import capture as shared
from capture import plain

# From vmmdll.h of the MemProcFS this lab carries: the connections map, version 3, the refresh of it alone, and those of the
# cached memory and page tables, which vmmnet.c builds the map from, so that without them a new connection stays unseen.
NET_VERSION, REFRESH_NET, REFRESH_MEMORY, REFRESH_PAGE_TABLES = 3, 0x2003000300000000, 0x2001100000000000, 0x2001080000000000
REFRESH_PROCESSES = 0x2001000100000000
# vmmnet.c names an entry UDP when its pool tag is UdpA and TCP otherwise, and its state by this list.
UDP_TAG = int.from_bytes(b"UdpA", "big")
STATES = ["CLOSED", "LISTENING", "SYN_SENT", "SYN_RCVD", "ESTABLISHED", "FIN_WAIT_1", "FIN_WAIT_2", "CLOSE_WAIT", "CLOSING", "LAST_ACK",
          "", "", "TIME_WAIT", ""]


class Side(ctypes.Structure):
    _fields_ = [("fValid", ctypes.c_int32), ("_Reserved", ctypes.c_uint16), ("port", ctypes.c_uint16), ("pbAddr", ctypes.c_uint8 * 16),
                ("uszText", ctypes.c_char_p)]


class NetEntry(ctypes.Structure):
    _fields_ = [("dwPID", ctypes.c_uint32), ("dwState", ctypes.c_uint32), ("_FutureUse3", ctypes.c_uint16 * 3), ("AF", ctypes.c_uint16),
                ("Src", Side), ("Dst", Side), ("vaObj", ctypes.c_uint64), ("ftTime", ctypes.c_uint64), ("dwPoolTag", ctypes.c_uint32),
                ("_FutureUse4", ctypes.c_uint32), ("uszText", ctypes.c_char_p), ("_FutureUse2", ctypes.c_uint32 * 4)]


class NetMap(ctypes.Structure):
    _fields_ = [("dwVersion", ctypes.c_uint32), ("_Reserved1", ctypes.c_uint32), ("pbMultiText", ctypes.c_void_p),
                ("cbMultiText", ctypes.c_uint32), ("cMap", ctypes.c_uint32)]


def endpoint(address, port):
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError:
        return None
    if parsed.version == 6 and parsed.ipv4_mapped:
        parsed = parsed.ipv4_mapped
    return f"[{parsed.compressed}]:{port}" if parsed.version == 6 else f"{parsed}:{port}"


class Memory:
    """The guest's connections as its memory holds them."""

    def __init__(self):
        spec = importlib.util.spec_from_file_location("windows", os.path.join(shared.SETTINGS.dbg, "windows.py"))
        windows = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(windows)
        device = os.environ.get("VM_INSPECT_DEVICE")
        if not device:
            raise LookupError("this needs the session's memory, which only vm-lab or vm-inspect gives")
        self.windows = windows.Windows(shared.SETTINGS.vmm, device)
        vmm = self.windows.vmm
        vmm.VMMDLL_ConfigSet.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64]
        vmm.VMMDLL_Map_GetNetU.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.POINTER(NetMap))]
        self.names, self.warned = {}, False

    def name(self, pid):
        if pid not in self.names:
            try:
                self.names[pid] = self.windows.process(pid)[0]
            except LookupError:
                self.names[pid] = "?"
        return self.names[pid]

    def sample(self):
        vmm, handle = self.windows.vmm, self.windows.handle
        for refresh in (REFRESH_MEMORY, REFRESH_PAGE_TABLES, REFRESH_NET):
            vmm.VMMDLL_ConfigSet(handle, refresh, 1)
        pointer = ctypes.POINTER(NetMap)()
        if not vmm.VMMDLL_Map_GetNetU(handle, ctypes.byref(pointer)):
            self.warn("MemProcFS gave no map of the guest's connections")
            return []
        try:
            header = pointer.contents
            if header.dwVersion != NET_VERSION:
                sys.exit(f"guest-net: MemProcFS's map of connections has version {header.dwVersion}, not the one this was written for")
            entries = ctypes.cast(ctypes.addressof(header) + ctypes.sizeof(NetMap), ctypes.POINTER(NetEntry))
            found = []
            for i in range(header.cMap):
                entry = entries[i]
                local = endpoint((entry.Src.uszText or b"").decode("ascii", "replace"), entry.Src.port) if entry.Src.fValid else None
                remote = endpoint((entry.Dst.uszText or b"").decode("ascii", "replace"), entry.Dst.port) if entry.Dst.fValid else None
                if not local or not entry.dwPID:
                    continue
                found.append({"proto": "udp" if entry.dwPoolTag == UDP_TAG else "tcp", "local": local, "remote": remote or "",
                              "pid": entry.dwPID, "process": plain(self.name(entry.dwPID), 200),
                              "state": STATES[entry.dwState] if entry.dwState < len(STATES) else "", "source": "memory"})
            if not found:
                self.warn("MemProcFS found no connection, where a running Windows always has some, so it likely lacks the symbols of tcpip.sys")
            return found
        finally:
            vmm.VMMDLL_MemFree(pointer)

    def processes(self):
        self.windows.vmm.VMMDLL_ConfigSet(self.windows.handle, REFRESH_PROCESSES, 1)
        return [{"pid": pid, "ppid": parent, "process": plain(name, 200), "source": "memory"} for pid, parent, name in self.windows.processes() if pid]

    def warn(self, message):
        if not self.warned:
            self.warned = True
            print(f"guest-net: {message}", file=sys.stderr)


# What ss -tunapH and busybox's netstat -tunap print for a connection.
SS = re.compile(r"(tcp|udp)\s+(\S+)\s+\d+\s+\d+\s+(\S+)\s+(\S+)\s+users:\(\(\"([^\"]*)\",pid=(\d+)")
NETSTAT = re.compile(r"(tcp|udp)6?\s+\d+\s+\d+\s+(\S+)\s+(\S+)\s+(?:([A-Z_0-9]+)\s+)?(\d+)/(\S+)")
LINUX = ["--shell", ("ss -tunapH 2>/dev/null || netstat -tunapW 2>/dev/null; "
                     "for f in /proc/[0-9]*/stat; do { read -r line < $f; } 2>/dev/null && echo \"process $line\"; done")]
# Windows' own view, one connection a line as LISTED reads it, since its netstat names no process without elevation.
WINDOWS = ["--powershell", r"""
$names = @{}
Get-Process | ForEach-Object { $names[$_.Id] = $_.ProcessName }
function at($address, $port) { if ($address -like '*:*') { "[$address]:$port" } else { "${address}:$port" } }
Get-NetTCPConnection | ForEach-Object {
    "tcp $(at $_.LocalAddress $_.LocalPort) $(at $_.RemoteAddress $_.RemotePort) $($_.State) $($_.OwningProcess) $($names[[int]$_.OwningProcess])" }
Get-NetUDPEndpoint | ForEach-Object { "udp $(at $_.LocalAddress $_.LocalPort) * - $($_.OwningProcess) $($names[[int]$_.OwningProcess])" }
Get-CimInstance Win32_Process | ForEach-Object { "process $($_.ProcessId) $($_.ParentProcessId) $($_.Name)" }
"""]
LISTED = re.compile(r"(tcp|udp) (\S+) (\S+) (\S+) (\d+) ?(.*)")
# A line of /proc/PID/stat, whose name is the text between the first parenthesis and the last, and one of WINDOWS.
STAT, CIM = re.compile(r"process (\d+) \((.*)\) \S+ (\d+) .*"), re.compile(r"process (\d+) (\d+) ?(.*)")


def split(text):
    """An address and port as ss or netstat print them, None for no remote end."""
    address, _, port = text.rpartition(":")
    address = address.strip("[]").split("%")[0]
    return endpoint(address or "0.0.0.0", port) if port.isdigit() and port != "0" else None


def parse(text):
    """The connections in what ss, netstat or WINDOWS printed."""
    found = []
    for line in text.splitlines():
        line = line.strip()
        if matched := SS.match(line):
            proto, state, local, remote, process, pid = matched.groups()
        elif matched := NETSTAT.match(line):
            proto, local, remote, state, pid, process = matched.groups()
        elif matched := LISTED.fullmatch(line):
            proto, local, remote, state, pid, process = matched.groups()
            state = "LISTENING" if state == "Listen" else "" if state == "-" else re.sub(r"(?<=[a-z])(?=[A-Z])", "_", state).upper()
        else:
            continue
        local = split(local)
        if local:
            found.append({"proto": proto, "local": local, "remote": split(remote) or "", "pid": int(pid), "process": plain(process, 200),
                          "state": state or "", "source": "agent"})
    return found


def parse_processes(text):
    """The processes in what LINUX or WINDOWS printed, each with the number of the one that started it."""
    found = []
    for line in text.splitlines():
        line = line.strip()
        if matched := STAT.fullmatch(line):
            pid, name, parent = matched.groups()
        elif matched := CIM.fullmatch(line):
            pid, parent, name = matched.groups()
        else:
            continue
        if int(pid) < 2 ** 32 and int(parent) < 2 ** 32:
            found.append({"pid": int(pid), "ppid": int(parent), "process": plain(name, 200), "source": "agent"})
    return found


def lineage(windows, pids):
    """The processes given and those that started them, up to the first that is gone, which is what --children follows."""
    out, seen = [], set()
    for pid in pids:
        while pid and pid not in seen and len(seen) < 4096:
            seen.add(pid)
            try:
                name, parent, _ = windows.information(pid)
            except LookupError:
                break
            out.append({"pid": pid, "ppid": parent, "process": plain(name, 200), "source": "memory"})
            pid = parent
    return out


class Agent:
    """The guest's connections and processes as its own tools tell them, through the agent."""

    def __init__(self):
        self.command, self.listed = None, []

    def sample(self):
        for command in [self.command] if self.command else [LINUX, WINDOWS]:
            done = subprocess.run(["guest-exec", "--timeout", "30", *command], capture_output=True, text=True, errors="replace", check=False)
            found = parse(done.stdout)
            if found:
                self.command, self.listed = command, parse_processes(done.stdout)
                return found
        if self.command:
            return []
        shared.fail(f"the guest's own tools named no connection: {plain(done.stderr.strip() or done.stdout.strip(), 300)}")
        return []

    def processes(self):
        """Those of the last sample, which asks for both at once."""
        return self.listed


def run(args):
    shared.find(args)
    reader = None
    if args.source in (None, "memory"):
        try:
            reader = Memory()
        except (LookupError, OSError) as e:
            if args.source == "memory":
                shared.fail(str(e))
            print(f"guest-net: the guest's memory cannot be read ({plain(e, 200)}), so its agent is asked instead", file=sys.stderr)
    if reader is None:
        reader = Agent()
    told, listed = set(), set()
    try:
        while True:
            fresh = [e for e in reader.sample() if (e["proto"], e["local"], e["remote"], e["pid"]) not in told]
            for at in range(0, len(fresh), 4096):
                shared.tell({"do": "note", "kind": "owners", "entries": fresh[at: at + 4096]})
            started = [p for p in reader.processes() if (p["pid"], p["ppid"], p["process"]) not in listed]
            for at in range(0, len(started), 4096):
                shared.tell({"do": "note", "kind": "processes", "entries": started[at: at + 4096]})
            listed |= {(p["pid"], p["ppid"], p["process"]) for p in started}
            for entry in fresh:
                told.add((entry["proto"], entry["local"], entry["remote"], entry["pid"]))
                print(f"{entry['proto']} {entry['local']} -> {entry['remote'] or '*'}  {entry['state']}  {entry['process']}[{entry['pid']}]")
            sys.stdout.flush()
            if not args.follow:
                return
            time.sleep(args.every)
    except KeyboardInterrupt:
        pass


def known(capture):
    return list(capture.lines("owners.jsonl"))


def best(found, flow):
    """The sighting of the program a flow belongs to, as the last look before it ended saw it, or None."""
    chosen = None
    for entry in found:
        if entry.get("proto") != flow["proto"] or entry.get("local") != flow["guest"]:
            continue
        if flow["proto"] == "tcp" and entry.get("remote") not in ("", flow["remote"]):
            continue
        if chosen is None or (entry.get("time", 0) <= flow["ended"] * 1e9 + 5e9 and entry.get("time", 0) >= chosen.get("time", 0)):
            chosen = entry
    return chosen


def owner_of(found, flow):
    chosen = best(found, flow)
    return f"{chosen.get('process')}[{chosen.get('pid')}]" if chosen else ""

"""Opens a running guest for inspection and runs a command that can reach its memory.

The guest's memory arrives as a descriptor from the root helper. Programs get at it through sockets in a folder of the
session: one hands the descriptor to whoever connects, one answers the one question LeechCore asks QEMU, where the
memory sits in the guest's address space, and one passes requests for a picture of the screen, for input or for the
agent in the guest on to the helper, which is the side that decides. What goes through it is written down in
~/.local/state/vm-inspect/DOMAIN.log, for the user to read what a tool did to the guest. A guest that shares frames through Looking Glass gets one more, which hands out
the memory they are in. All end with the command.

A session opened with --net or --usb records what the guest sends and gets over its network and USB devices, which the
helper passes on. It goes into files of a folder of its own under ~/.local/state/vm-inspect/captures, in the format
Wireshark reads, and nothing of it is looked into here. Tools mark moments there and add what they found out, such as
which program a connection belongs to, through the control socket, which this side answers itself.
"""
import argparse
import base64
import glob
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

# The helper's limit, kept here too so that a request it would end the session over never reaches it.
REQUEST = 120 * 1024
GREETING = {"QMP": {"version": {"qemu": {"major": 0, "minor": 0, "micro": 0}, "package": "vm-inspect"}, "capabilities": []}}


def fail(message):
    print(f"vm-inspect: {message}", file=sys.stderr)
    sys.exit(1)


def listen(path):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(8)
    return server


def serve(server, answer):
    while True:
        try:
            conn, _ = server.accept()
        except OSError:
            return
        threading.Thread(target=answer, args=(conn,), daemon=True).start()


def hand_over(ram):
    def answer(conn):
        with conn:
            try:
                socket.send_fds(conn, [b"F"], [ram])
            except OSError:
                pass
    return answer


def memory_map(mtree):
    """Stands in for a QEMU monitor, with the one answer that tells where the guest's memory is mapped."""
    text = "\r\n".join(mtree.splitlines()) + "\r\n"

    def reply(request):
        command = request.get("execute")
        if command == "qmp_capabilities":
            return {"return": {}}
        if command == "human-monitor-command" and request.get("arguments", {}).get("command-line") == "info mtree -f":
            return {"return": text}
        return {"error": {"class": "CommandNotFound", "desc": "this socket only tells where the guest's memory is mapped"}}

    def answer(conn):
        with conn, conn.makefile("rwb") as stream:
            try:
                stream.write(json.dumps(GREETING).encode() + b"\r\n")
                stream.flush()
                for line in stream:
                    try:
                        request = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(request, dict):
                        continue
                    stream.write(json.dumps({**reply(request), "id": request.get("id")}).encode() + b"\r\n")
                    stream.flush()
            except OSError:
                pass
    return answer


def block(kind, body):
    """One block of a pcapng file."""
    body += b"\0" * (-len(body) % 4)
    return struct.pack("<II", kind, len(body) + 12) + body + struct.pack("<I", len(body) + 12)


def option(code, value):
    return struct.pack("<HH", code, len(value)) + value + b"\0" * (-len(value) % 4)


def pcapng(interfaces):
    """The head of a pcapng file: its section and one block for each interface, as link type, name, what it is and the time's resolution."""
    head = block(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1) + option(4, b"vm-inspect") + option(0, b""))
    for linktype, name, said, resolution in interfaces:
        head += block(1, struct.pack("<HHI", linktype, 0, 0) + option(2, name.encode()) + option(3, said.encode())
                      + option(9, bytes([resolution])) + option(0, b""))
    return head


def packet(interface, stamp, data, length, flags=None):
    """One packet of a pcapng file. flags carries the direction, 1 for what came in and 2 for what went out."""
    body = struct.pack("<IIIII", interface, stamp >> 32, stamp & 0xFFFFFFFF, len(data), length) + data + b"\0" * (-len(data) % 4)
    if flags is not None:
        body += option(2, struct.pack("<I", flags)) + option(0, b"")
    return block(6, body)


# Lines of a TLS key log, as Wireshark reads them, and nothing else.
KEYLOG = re.compile(r"(?:CLIENT_RANDOM|RSA|CLIENT_EARLY_TRAFFIC_SECRET|CLIENT_HANDSHAKE_TRAFFIC_SECRET|SERVER_HANDSHAKE_TRAFFIC_SECRET|"
                    r"CLIENT_TRAFFIC_SECRET_0|SERVER_TRAFFIC_SECRET_0|EARLY_EXPORTER_SECRET|EXPORTER_SECRET) [0-9a-fA-F]{16,128} [0-9a-fA-F]{32,256}")
# The traffic secrets of TLS 1.3 after key updates, which no key log of Wireshark takes and guest-net opens itself.
UPDATED = re.compile(r"(?:CLIENT|SERVER)_TRAFFIC_SECRET_[1-9][0-9]{0,5} [0-9a-fA-F]{64} [0-9a-fA-F]{64,96}")
# What a tool may say about a connection or a process, and how long each part may be.
OWNER_FIELDS, NOTED = ("proto", "local", "remote", "pid", "process", "state", "seen", "source"), 4096
PROCESS_FIELDS = ("pid", "ppid", "process", "source")


class Capture:
    """What a session records of its guest, in a folder the user keeps.

    net.pcapng holds a block for each network device and the frames, seen from the guest: outbound is what it sent.
    usb.pcapng holds the records of the USB monitor for the devices the guest has. capture.json says what was recorded
    and how it ended, notes.jsonl holds the moments tools marked, owners.jsonl which program a connection was
    found to be of, processes.jsonl which program started which, keys.log the TLS secrets that tools found, for
    whatever reads the capture to decrypt with, and updated.log those of TLS 1.3 after key updates.
    """

    def __init__(self, domain, recorded, limit):
        state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
        self.folder = os.path.join(state, "vm-inspect", "captures", domain, time.strftime("%Y%m%d-%H%M%S"))
        os.makedirs(self.folder, mode=0o700)
        self.recorded, self.limit, self.lock = recorded, limit, threading.Lock()
        self.written, self.stopped, self.counts, self.started = 0, None, {}, time.time()
        self.net = self.usb = None
        if recorded["net"]:
            self.net = self.open("net.pcapng", pcapng(
                [(1, t["name"], f"the network device {t['mac']} of {domain}, seen from the guest: outbound is what it sent", 9)
                 for t in recorded["net"]]))
        if recorded["usb"] is not None:
            self.usb = self.open("usb.pcapng", pcapng([(220, "usb", f"the USB devices {domain} has", 6)]))
        self.describe()

    def open(self, name, head):
        descriptor = os.open(os.path.join(self.folder, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND | os.O_CLOEXEC, 0o600)
        os.write(descriptor, head)
        self.written += len(head)
        return descriptor

    def describe(self, ended=None):
        said = {"started": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.started)), **self.recorded, "limit": self.limit,
                "bytes": self.written, "stopped": self.stopped, **self.counts}
        if ended:
            said["ended"] = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ended))
        path = os.path.join(self.folder, "capture.json")
        with open(os.open(path + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            json.dump(said, f, indent=1)
        os.replace(path + ".new", path)

    def keep(self, descriptor, written):
        """Adds a block to a file, unless the session has written as much as it may or the disk is nearly full."""
        if self.stopped:
            return
        if self.written + len(written) > self.limit:
            self.stopped = f"the limit of {self.limit} bytes was reached"
        elif self.written // (64 * 1024 * 1024) != (self.written + len(written)) // (64 * 1024 * 1024):
            space = os.statvfs(self.folder)
            if space.f_bavail * space.f_frsize < 512 * 1024 * 1024:
                self.stopped = "less than 512 MiB were left on the disk"
        if self.stopped:
            print(f"vm-inspect: the capture stopped, {self.stopped}", file=sys.stderr)
            return
        os.write(descriptor, written)
        self.written += len(written)

    def take(self, stream):
        """Writes what the helper passes on until it stops."""
        with stream.makefile("rb") as f:
            while True:
                head = f.read(5)
                if len(head) < 5:
                    return
                payload = f.read(struct.unpack_from("<I", head, 1)[0])
                if head[:1] == b"N" and self.net is not None and len(payload) >= 14:
                    index, sent, stamp, length = struct.unpack_from("<BBQI", payload)
                    self.keep(self.net, packet(index, stamp, payload[14:], length, 2 if sent else 1))
                elif head[:1] == b"U" and self.usb is not None and len(payload) >= 64:
                    seconds, microseconds = struct.unpack_from("<qi", payload, 16)
                    asked_for, ndesc = struct.unpack_from("<I", payload, 32)[0], struct.unpack_from("<I", payload, 60)[0]
                    # As libpcap counts it: the header, the ISO descriptors and all the transfer asked for.
                    length = max(64 + ndesc * 16 + asked_for, len(payload))
                    self.keep(self.usb, packet(0, seconds * 1_000_000 + microseconds, payload, length))
                elif head[:1] == b"S":
                    try:
                        self.counts = json.loads(payload)
                    except ValueError:
                        continue
                    # Every few seconds, so that what reads the capture meanwhile sees how far it got.
                    self.describe()

    def note(self, request):
        """What a tool adds to the capture: a mark, the owners of connections, processes or TLS secrets. Its answer, as for any request."""
        stamp = time.time_ns()
        if request.get("do") == "mark":
            label = request.get("label")
            if not isinstance(label, str) or not 0 < len(label) <= 120 or STEERING.search(label):
                return {"error": "a mark is a label of up to 120 plain characters"}
            return self.append("notes.jsonl", [json.dumps({"time": stamp, "mark": label})])
        kind = request.get("kind")
        if kind == "keys":
            lines = request.get("lines")
            if not isinstance(lines, list) or len(lines) > NOTED or not all(isinstance(l, str) and KEYLOG.fullmatch(l) for l in lines):
                return {"error": f"keys are up to {NOTED} lines of a TLS key log"}
            return self.append("keys.log", lines)
        if kind == "owners":
            entries = request.get("entries")
            if not isinstance(entries, list) or len(entries) > NOTED or not all(owner(e) for e in entries):
                return {"error": f"owners are up to {NOTED} connections, each with {', '.join(OWNER_FIELDS)} as text or whole numbers"}
            return self.append("owners.jsonl", [json.dumps({"time": stamp, **e}) for e in entries])
        if kind == "updated":
            lines = request.get("lines")
            if not isinstance(lines, list) or len(lines) > NOTED or not all(isinstance(l, str) and UPDATED.fullmatch(l) for l in lines):
                return {"error": f"updated keys are up to {NOTED} lines of a traffic secret after key updates"}
            return self.append("updated.log", lines)
        if kind == "processes":
            entries = request.get("entries")
            if not isinstance(entries, list) or len(entries) > NOTED or not all(owner(e, PROCESS_FIELDS) for e in entries):
                return {"error": f"processes are up to {NOTED}, each with {', '.join(PROCESS_FIELDS)} as text or whole numbers"}
            return self.append("processes.jsonl", [json.dumps({"time": stamp, **e}) for e in entries])
        return {"error": "a note is of keys, updated keys, owners or processes"}

    def append(self, name, lines):
        with self.lock, open(os.open(os.path.join(self.folder, name), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "a") as f:
            f.write("".join(line + "\n" for line in lines))
        return {"folder": self.folder}

    def close(self, ended):
        for descriptor in (self.net, self.usb):
            if descriptor is not None:
                os.close(descriptor)
        self.describe(ended)


def owner(entry, fields=OWNER_FIELDS):
    return (isinstance(entry, dict) and set(entry) <= set(fields)
            and all((isinstance(v, str) and len(v) <= 256 and not STEERING.search(v)) or (type(v) is int and 0 <= v < 2 ** 32)
                    for v in entry.values()))


def read_line(conn, limit=REQUEST):
    """One line and the descriptors that came with it. None when the other end closed or sent too much."""
    line, descriptors = b"", []
    while not line.endswith(b"\n"):
        if len(line) > limit:
            return None, descriptors
        more, received, _, _ = socket.recv_fds(conn, 4096, 4)
        descriptors += received
        if not more:
            return None, descriptors
        line += more
    return line, descriptors


# Asked over and over while a file moves or a program is waited for, which would bury what the log is for.
UNRECORDED = ("guest-ping", "guest-exec-status", "guest-file-read", "guest-file-write", "guest-file-seek", "guest-file-flush", "guest-file-close")
STEERING = re.compile(r"[\x00-\x1f\x7f-\x9f]")
# A script handed to PowerShell and the values that go with it, both unreadable as they are sent.
ENCODED = re.compile(r"(?<=-EncodedCommand )[A-Za-z0-9+/=]{8,}")
PACKED = re.compile(r"\[Convert\]::FromBase64String\('([A-Za-z0-9+/=]*)'\)")


def asked(request):
    """What a request wants of the guest, in a few words. None for one that is not worth a line."""
    try:
        request = json.loads(request)
    except ValueError:
        return "something that is no request"
    if not isinstance(request, dict):
        return "something that is no request"
    if request.get("do") == "input" and isinstance(request.get("events"), list):
        # What goes down comes up again, which says nothing new.
        said = [f"{e.get('type')} {e.get('key') or e.get('button') or e.get('axis')}{'' if 'down' in e else ' ' + str(e.get('value'))}"
                for e in request["events"][:8] if isinstance(e, dict) and e.get("down") is not False]
        return "input: " + ", ".join(said) if said else None
    if request.get("do") == "disk":
        return f"a file plugged into the guest as a disk it may {'write' if request.get('write') is True else 'read'}"
    if request.get("do") == "push":
        return f"push {request.get('size')} bytes into the file held as {request.get('handle')}"
    if request.get("do") == "mark":
        return f"mark {request.get('label')}"
    if request.get("do") == "note":
        return None
    if request.get("do") != "agent":
        return str(request.get("do"))
    execute, arguments = str(request.get("execute")), request.get("arguments")
    if execute in UNRECORDED:
        return None
    arguments = arguments if isinstance(arguments, dict) else {}
    words = [str(arguments.get("path", ""))] + [str(word) for word in (arguments.get("arg") or []) if isinstance(arguments.get("arg"), list)]
    said = ENCODED.sub(lambda found: readable(found.group(0), "utf-16-le"), " ".join(words))
    said = PACKED.sub(lambda found: readable(found.group(1), "utf-8"), said)
    return f"{execute} {said} {arguments.get('mode', '')}".strip()


def readable(sent, encoding):
    try:
        return base64.b64decode(sent).decode(encoding, "replace")
    except ValueError:
        return sent


def record(log, request, reply):
    """Adds a line to the session's log, which is the user's to read: what was asked of the guest, and how it went."""
    what = asked(request)
    if log is None or what is None:
        return
    try:
        refused = json.loads(reply).get("error") if reply else "the session ended"
    except (ValueError, AttributeError):
        refused = "an answer that makes no sense"
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {STEERING.sub(' ', what)[:600]} -> {'done' if refused is None else 'refused: ' + STEERING.sub(' ', str(refused))[:200]}\n"
    try:
        if os.path.exists(log) and os.path.getsize(log) > 8 * 1024 * 1024:
            os.replace(log, log + ".1")
        with open(os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "w") as f:
            f.write(line)
    except OSError:
        pass


def control(helper, log, capture):
    """Passes one request per connection to the helper. One at a time, since its answers come back in order.

    Marks and notes for the capture are answered here and never reach the helper.
    """
    turn = threading.Lock()

    def answer(conn):
        with conn:
            descriptors = []
            try:
                conn.settimeout(10)
                request, descriptors = read_line(conn)
                if request is None or len(descriptors) > 1:
                    conn.sendall(json.dumps({"error": "a request is one line of at most 120 KiB, with one file at most"}).encode() + b"\n")
                    return
                own = for_capture(request)
                if own is not None:
                    reply = (capture.note(own) if capture else
                             {"error": "this session records nothing, it was opened without --net or --usb"})
                    reply = json.dumps(reply).encode() + b"\n"
                    record(log, request, reply)
                    conn.sendall(reply)
                    return
                with turn:
                    # A file to push travels on with its request.
                    if descriptors:
                        socket.send_fds(helper, [request], descriptors)
                        os.close(descriptors.pop())
                    else:
                        helper.sendall(request)
                    reply, descriptors = read_line(helper)
                    record(log, request, reply)
                if reply is None:
                    return
                if descriptors:
                    socket.send_fds(conn, [reply], descriptors)
                else:
                    conn.sendall(reply)
            except OSError:
                pass
            finally:
                for descriptor in descriptors:
                    os.close(descriptor)
    return answer


def for_capture(request):
    """The request when it is one the session answers for its capture, None for anything that goes to the helper."""
    try:
        request = json.loads(request)
    except ValueError:
        return None
    return request if isinstance(request, dict) and request.get("do") in ("mark", "note") else None


def session_log(domain):
    """Where the session writes what tools asked of the guest. None when there is no place for it."""
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    try:
        os.makedirs(os.path.join(state, "vm-inspect"), mode=0o700, exist_ok=True)
    except OSError:
        return None
    return os.path.join(state, "vm-inspect", f"{domain}.log")


def session_env(domain, folder, gdb, capture):
    env = dict(os.environ)
    env["VM_INSPECT_DOMAIN"] = domain
    env["VM_INSPECT_DIR"] = folder
    env["VM_INSPECT_DEVICE"] = f"qemu://ram={folder}/ram.sock,qmp={folder}/qmp.sock"
    for name, value in (("VM_INSPECT_GDB", gdb), ("VM_INSPECT_CAPTURE", capture)):
        if value:
            env[name] = value
        else:
            env.pop(name, None)
    return env


def join(domain, folder, command):
    """Runs the command against a session another vm-inspect has open, for a second terminal or a sandbox it is shared with."""
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.connect(os.path.join(folder, "ram.sock"))
    except OSError:
        fail(f"{domain} has no session open here, start one with vm-inspect {domain}")
    finally:
        probe.close()
    stubs = [p for p in sorted(glob.glob(f"/run/vm-inspect/{glob.escape(domain)}.*/gdb.sock")) if os.access(p, os.R_OK | os.W_OK)]
    try:
        with open(os.path.join(folder, "capture")) as f:
            capture = f.read().strip()
    except OSError:
        capture = None
    try:
        os.execvpe(command[0], command, session_env(domain, folder, stubs[0] if stubs else None, capture))
    except OSError as e:
        fail(str(e))


def main():
    parser = argparse.ArgumentParser(
        prog="vm-inspect",
        usage="vm-inspect [--gdb] [--control] [--net] [--usb] [--plug DEVICE]... DOMAIN [-- COMMAND...] | vm-inspect --join DOMAIN [-- COMMAND...]",
        description="Open a running guest for inspection and run COMMAND, or a shell, with its memory in reach.",
        epilog="Inside, $VM_INSPECT_DEVICE is the LeechCore device (memprocfs -device \"$VM_INSPECT_DEVICE\" -mount DIR) "
               "and, with --gdb, $VM_INSPECT_GDB is QEMU's debug socket (gdb -ex \"target remote $VM_INSPECT_GDB\"). "
               "The guest stops while a debugger is attached, so detach before you quit it. "
               "guest-shot saves a picture of the guest's screen, and with --control guest-input sends it keys and pointer events. "
               "With --net or --usb, $VM_INSPECT_CAPTURE is the folder the session records into.")
    parser.add_argument("settings", help=argparse.SUPPRESS)
    parser.add_argument("--gdb", action="store_true", help="also open QEMU's debug stub for the session")
    parser.add_argument("--control", action="store_true",
                        help="also let the session send keys and pointer events to the guest and talk to the agent in it")
    parser.add_argument("--net", action="store_true", help="record what the guest sends and gets over its network devices, from this side")
    parser.add_argument("--usb", action="store_true", help="record the traffic of the USB devices passed to the guest, from this side")
    parser.add_argument("--plug", action="append", default=[], metavar="DEVICE",
                        help="pass a USB device of this system to the guest for the session, by vendor and product as 046d:c52b "
                             "or by its place as 3-1.4. It is gone from this system until the session ends")
    parser.add_argument("--keep", action="store_true", help="keep what the session records when it ends, which capture.keep decides otherwise")
    parser.add_argument("--join", action="store_true", help="use the session that is already open, without opening the guest again")
    parser.add_argument("domain")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    with open(args.settings) as f:
        settings = json.load(f)
    if args.domain not in settings["domains"]:
        fail(f"{args.domain} is not among the domains that may be inspected ({', '.join(settings['domains']) or 'none'})")
    keep = args.keep or settings.get("capture_keep", True)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    command = command or [os.environ.get("SHELL") or "/bin/sh"]
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        fail("XDG_RUNTIME_DIR is not set")
    folder = os.path.join(runtime, "vm-inspect", args.domain)
    if args.join:
        join(args.domain, folder, command)

    ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    options = [f"--{name}" for name in ("gdb", "control", "net", "usb") if getattr(args, name)]
    options += [f"--plug={device}" for device in args.plug]
    helper = subprocess.Popen([settings["pkexec"], settings["helper"], args.domain] + options, stdin=theirs)
    theirs.close()
    try:
        _, descriptors, _, _ = socket.recv_fds(ours, 1, 8)
    except OSError:
        descriptors = []
    if not descriptors:
        helper.wait()
        sys.exit(helper.returncode or 1)
    with ours.makefile("rb") as stream:
        info = json.loads(stream.readline())
    handed = dict(zip(info["descriptors"], descriptors))

    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder, mode=0o700)
    capture, taking = None, None
    if "recorder" in handed:
        capture = Capture(args.domain, info["recorded"], settings["capture_limit"])
        recorder = socket.socket(fileno=handed["recorder"])
        taking = threading.Thread(target=capture.take, args=(recorder,), daemon=True)
        taking.start()
        with open(os.open(os.path.join(folder, "capture"), os.O_WRONLY | os.O_CREAT, 0o600), "w") as f:
            f.write(capture.folder)
        for left in info["recorded"]["left"]:
            print(f"vm-inspect: not recorded: {left}", file=sys.stderr)
        if args.net and not info["recorded"]["net"]:
            print("vm-inspect: the guest has no network device to record", file=sys.stderr)
        if args.usb and not info["recorded"]["usb"]:
            print("vm-inspect: the guest has no USB device yet, one passed to it later is recorded from then on", file=sys.stderr)
        print(f"vm-inspect: recording into {capture.folder}{'' if keep else ', deleted when the session ends unless it is opened with --keep'}",
              file=sys.stderr)
    servers = [(listen(os.path.join(folder, "ram.sock")), hand_over(handed["ram"])),
               (listen(os.path.join(folder, "qmp.sock")), memory_map(info["mtree"])),
               (listen(os.path.join(folder, "control.sock")), control(ours, session_log(args.domain), capture))]
    if "frames" in handed:
        servers.append((listen(os.path.join(folder, "frames.sock")), hand_over(handed["frames"])))
    for server, answer in servers:
        threading.Thread(target=serve, args=(server, answer), daemon=True).start()

    # A session ended from outside still closes the guest and takes its folder along.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda number, _: sys.exit(128 + number))
    status, child = 1, None
    try:
        child = subprocess.Popen(command, env=session_env(args.domain, folder, info["gdb"], capture.folder if capture else None))
        status = child.wait()
    except OSError as e:
        print(f"vm-inspect: {e}", file=sys.stderr)
    except KeyboardInterrupt:
        status = 130
    finally:
        if child and child.poll() is None:
            child.terminate()
        for server, _ in servers:
            server.close()
        shutil.rmtree(folder, ignore_errors=True)
        ours.close()
        try:
            helper.wait(timeout=60)
        except subprocess.TimeoutExpired:
            pass
        if capture:
            taking.join(30)
            capture.close(time.time())
            if keep:
                print(f"vm-inspect: recorded {capture.written} bytes into {capture.folder}", file=sys.stderr)
            else:
                shutil.rmtree(capture.folder, ignore_errors=True)
                print(f"vm-inspect: recorded {capture.written} bytes, deleted with the session as capture.keep says, --keep keeps them",
                      file=sys.stderr)
    sys.exit(status)


if __name__ == "__main__":
    main()

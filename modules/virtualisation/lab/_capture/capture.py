"""What guest-net and guest-usb share: the capture a session records, its marks and notes, and tshark to read it with.

Everything in a capture was sent or received by the guest. tshark makes sense of it inside lab-box, with no network, no
guest and none of this side's files but the capture, and whatever it says is shown with the characters a terminal acts
on taken out.
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

STEERING = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
KEYLOG = re.compile(r"(?:CLIENT_RANDOM|RSA|CLIENT_EARLY_TRAFFIC_SECRET|CLIENT_HANDSHAKE_TRAFFIC_SECRET|SERVER_HANDSHAKE_TRAFFIC_SECRET|"
                    r"CLIENT_TRAFFIC_SECRET_0|SERVER_TRAFFIC_SECRET_0|EARLY_EXPORTER_SECRET|EXPORTER_SECRET) [0-9a-fA-F]{16,128} [0-9a-fA-F]{32,256}")
# The traffic secrets of TLS 1.3 and QUIC after key updates, which no key log of Wireshark takes.
UPDATED = re.compile(r"(?:CLIENT|SERVER)_TRAFFIC_SECRET_[1-9][0-9]{0,5} [0-9a-fA-F]{64} [0-9a-fA-F]{64,96}")


class Settings:
    """Where the programs are, as the wrapper gives them before the arguments. dbg is guest-dbg's folder, whose readers of gdb and
    MemProcFS are used, scan the library keys scan searches with, and protoc what names gRPC's fields."""

    def __init__(self, tool, wireshark, box, vmm, dbg, gdb, scan, protoc):
        self.tool, self.tshark, self.editcap = tool, f"{wireshark}/tshark", f"{wireshark}/editcap"
        self.box, self.vmm, self.dbg, self.gdb, self.scan, self.protoc = box, vmm, dbg, gdb, scan, protoc


def fail(message):
    print(f"guest-{SETTINGS.tool if SETTINGS else 'capture'}: {message}", file=sys.stderr)
    sys.exit(1)


SETTINGS = None


def plain(text, limit=400):
    """Text of the guest, made safe to print: nothing a terminal acts on, and no more than the limit."""
    text = STEERING.sub("?", str(text))
    return text if len(text) <= limit else text[:limit] + f"... ({len(text)} characters)"


def size(count):
    for unit, scale in (("GB", 10 ** 9), ("MB", 10 ** 6), ("KB", 10 ** 3)):
        if count >= scale:
            return f"{count / scale:.1f} {unit}"
    return f"{count} B"


def captures_root():
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "vm-inspect", "captures")


class Capture:
    """One capture folder, as the session wrote it."""

    def __init__(self, folder):
        self.folder = os.path.realpath(folder)
        try:
            with open(os.path.join(self.folder, "capture.json")) as f:
                self.said = json.load(f)
        except (OSError, ValueError):
            fail(f"{folder} is no capture of a session")
        self.marks = []
        for line in self.lines("notes.jsonl"):
            if isinstance(line.get("mark"), str) and type(line.get("time")) is int:
                self.marks.append((line["mark"], line["time"] / 1e9))
        self.started = time.mktime(time.strptime(self.said["started"], "%Y-%m-%d %H:%M:%S"))
        # More options of tshark for every reading, as a capture guest-net wrote itself needs to say how its ports read.
        self.options = []

    def lines(self, name):
        try:
            with open(os.path.join(self.folder, name)) as f:
                for line in f:
                    try:
                        parsed = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(parsed, dict):
                        yield parsed
        except OSError:
            return

    def own_keys(self, flow):
        """The keys of a program's own crypto that keys own found for a flow, once each, as decode hands them to a decoder."""
        found = {}
        for line in self.lines("own.jsonl"):
            if line.get("flow") == flow:
                entry = {field: str(line.get(field, "")) for field in ("cipher", "key", "iv", "address", "process")}
                found.setdefault((entry["cipher"], entry["key"], entry["iv"]), entry)
        return list(found.values())

    def file(self, name):
        path = os.path.join(self.folder, name)
        if not os.path.exists(path):
            fail(f"this capture has no {name}, the session was not opened to record it")
        return path

    def moment(self, said):
        """A mark's time by its label, the last one of that name, or seconds from the start."""
        found = [stamp for label, stamp in self.marks if label == said]
        if found:
            return found[-1]
        try:
            return self.started + float(said)
        except ValueError:
            fail(f"{said} is neither a mark of this capture ({', '.join(sorted({l for l, _ in self.marks})) or 'none'}) nor seconds from its start")

    def window(self, args):
        """The display filter for --since and --until, empty when neither is given."""
        parts = []
        if getattr(args, "since", None):
            parts.append(f"frame.time_epoch >= {self.moment(args.since):.9f}")
        if getattr(args, "until", None):
            parts.append(f"frame.time_epoch <= {self.moment(args.until):.9f}")
        return " && ".join(parts)

    def ended(self):
        """Whether the session that wrote the capture has ended, so that it grows no more."""
        try:
            with open(os.path.join(self.folder, "capture.json")) as f:
                return bool(json.load(f).get("ended"))
        except (OSError, ValueError):
            return False

    def relative(self, stamp):
        return f"+{float(stamp) - self.started:.2f}s"

    def tshark(self, file, arguments, keys=None, stdin=None, binds=(), check=True):
        """Runs tshark on a file of the capture inside lab-box and gives back the process, its output still to be read."""
        box = [SETTINGS.box, "--ro", self.folder]
        options = []
        keylog = self.keylog(keys)
        if keylog:
            box += ["--ro", keylog]
            options += ["-o", f"tls.keylog_file:{keylog}"]
        for bind in binds:
            box += bind
        source = ["-i", "-"] if file is None else ["-r", self.file(file)]
        command = [*box, "--", SETTINGS.tshark, "-n", *source, *options, *self.options, *arguments]
        return subprocess.Popen(command, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def keylog(self, extra):
        """The capture's TLS secrets and those of a file given, together in one file, or None when there are none."""
        mine = os.path.join(self.folder, "keys.log")
        lines = []
        for path in [mine] + ([extra] if extra else []):
            try:
                with open(path, errors="replace") as f:
                    lines += [line.strip() for line in f if KEYLOG.fullmatch(line.strip())]
            except OSError:
                if path != mine:
                    fail(f"{path} cannot be read")
        if not lines:
            return None
        if not extra:
            return mine
        with tempfile.NamedTemporaryFile("w", prefix="keys-", suffix=".log", delete=False) as merged:
            merged.write("\n".join(lines) + "\n")
        return merged.name

    def ek(self, file, fields, display="", keys=None):
        """Each packet that matches, as a dictionary of the fields asked for, each a list of text."""
        arguments = (["-Y", display] if display else []) + ["-T", "ek"] + [a for f in fields for a in ("-e", f)]
        process = self.tshark(file, arguments, keys)
        for line in process.stdout:
            if not line.startswith(b'{"timestamp"'):
                continue
            try:
                layers = json.loads(line).get("layers", {})
            except ValueError:
                continue
            yield {field: layers.get(field.replace(".", "_"), []) for field in fields}
        finished(process)

    def output(self, file, arguments, keys=None):
        """What tshark prints for the arguments, as text."""
        process = self.tshark(file, arguments, keys)
        text = process.stdout.read().decode("utf-8", "replace")
        finished(process)
        return text


def finished(process):
    process.wait()
    if process.returncode != 0:
        said = [line.strip() for line in process.stderr.read().decode("utf-8", "replace").splitlines() if line.strip()]
        # tshark says what went wrong first, and for a display filter follows it with the filter and a caret under the fault.
        reason = next((line.removeprefix("tshark: ") for line in said if line.startswith("tshark: ")), said[-1] if said else "it gave no reason")
        fail(f"tshark could not read the capture: {plain(reason)}")


def first(packet, field, default=""):
    values = packet.get(field) or []
    return values[0] if values else default


def located(folder):
    """The session names its capture by the host's path, which a lab started inside another sandbox has under that sandbox's home."""
    if os.path.isdir(folder):
        return folder
    moved = os.path.join(captures_root(), *os.path.normpath(folder).split(os.sep)[-2:])
    return moved if os.path.isdir(moved) else folder


def find(args):
    """The capture to read: the one given, the one of the session this runs in, or the newest of its guest."""
    if getattr(args, "capture", None):
        return Capture(args.capture)
    if os.environ.get("VM_INSPECT_CAPTURE"):
        return Capture(located(os.environ["VM_INSPECT_CAPTURE"]))
    domain = os.environ.get("VM_INSPECT_DOMAIN")
    root = os.path.join(captures_root(), domain) if domain else None
    if root and os.path.isdir(root):
        found = sorted(entry for entry in os.listdir(root) if os.path.isfile(os.path.join(root, entry, "capture.json")))
        if found:
            print(f"guest-{SETTINGS.tool}: this session records nothing, so this reads the newest capture of {domain}: {found[-1]}", file=sys.stderr)
            return Capture(os.path.join(root, found[-1]))
    fail("there is no capture here: open the session with --net or --usb, or name one with --capture")


def listing(args):
    """The captures of the guest, or of every guest, newest last."""
    root = captures_root()
    domains = [args.domain] if args.domain else sorted(os.listdir(root)) if os.path.isdir(root) else []
    for domain in domains:
        folder = os.path.join(root, domain)
        for entry in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
            try:
                with open(os.path.join(folder, entry, "capture.json")) as f:
                    said = json.load(f)
            except (OSError, ValueError):
                continue
            what = [w for w, there in (("net", said.get("net")), ("usb", said.get("usb") is not None)) if there]
            print(f"{domain}/{entry}  {'+'.join(what) or 'nothing'}  {size(said.get('bytes', 0))}"
                  f"{'  stopped: ' + plain(said['stopped']) if said.get('stopped') else ''}{'' if said.get('ended') else '  still recording'}")


WARNED = set()


def ask(request):
    """Asks the open session to add something to its capture: its answer, or None and why there is none."""
    folder = os.environ.get("VM_INSPECT_DIR")
    if not folder:
        return None, "this needs an open session, which writes the capture"
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(30)
    try:
        conn.connect(os.path.join(folder, "control.sock"))
        conn.sendall(json.dumps(request).encode() + b"\n")
        reply = b""
        while not reply.endswith(b"\n"):
            more = conn.recv(4096)
            if not more:
                break
            reply += more
    except OSError as e:
        return None, f"the session did not answer: {e}"
    finally:
        conn.close()
    try:
        reply = json.loads(reply)
    except ValueError:
        return None, "the session gave no answer"
    if not isinstance(reply, dict):
        return None, "the session gave no answer"
    if "error" in reply:
        return None, str(reply["error"])
    return reply, None


def tell(request, needed=True):
    """Asks the open session to add something to its capture, and its answer. What is not needed only warns, once, when the
    session refuses it, as one of an older build does a kind of note it does not know."""
    reply, error = ask(request)
    if error and needed:
        fail(error)
    if error and request.get("kind") not in WARNED:
        WARNED.add(request.get("kind"))
        print(f"guest-{SETTINGS.tool}: the session keeps no {request.get('kind')} ({plain(error, 200)}), so they are left out", file=sys.stderr)
    return reply


def run_decoder(script, given, arguments=()):
    """Runs a decoder of a program's own protocol, a Python script, inside lab-box with what it is given as JSON on its standard
    input, and gives back the finished process."""
    script = os.path.realpath(script)
    if not os.path.isfile(script):
        fail(f"there is no decoder {script}")
    command = [SETTINGS.box, "--ro", script, "--", sys.executable, "-I", "-B", script, *arguments]
    return subprocess.run(command, input=json.dumps(given).encode(), capture_output=True, check=False)


def timed(parser):
    parser.add_argument("--since", metavar="MARK", help="only from this mark on, or from this many seconds after the start")
    parser.add_argument("--until", metavar="MARK", help="only up to this mark, or up to this many seconds after the start")


def common(parser):
    parser.add_argument("--capture", metavar="FOLDER", help="a capture other than the session's, as guest-net captures lists them")

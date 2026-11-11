import argparse
import collections
import glob
import hashlib
import itertools
import json
import os
import pwd
import queue
import re
import select
import shlex
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
import types

TYPE_INIT = 0x80
CTAPHID_MSG = TYPE_INIT | 0x03
CTAPHID_CBOR = TYPE_INIT | 0x10
CTAPHID_KEEPALIVE = TYPE_INIT | 0x3B
CTAPHID_ERROR = TYPE_INIT | 0x3F
STATUS_UPNEEDED = 0x02
U2F_SW_NO_ERROR = 0x9000
U2F_SW_CONDITIONS_NOT_SATISFIED = 0x6985
# A YubiKey answers an expired touch wait with OPERATION_DENIED, not USER_ACTION_TIMEOUT.
CTAP2_ENDINGS = {0x00: "touched", 0x27: "not touched", 0x2D: "cancelled", 0x2F: "not touched"}
FIDO_USAGE_PAGE = 0xF1D0
FIDO_USAGE_CTAPHID = 0x01

# Same timings as yubikey-touch-detector: keepalives arrive every ~100 ms while the key waits, a reply ends the wait at once.
WAIT_GRACE = 2.0
REPLY_GRACE = 0.2
MAX_CLIENTS = 4

TRACING = "/sys/kernel/tracing"
# A key answers a request with a first keepalive within ~100 ms, so whoever made it wait sent something shortly before.
SEND_WINDOW = 2.0
# hidraw ioctls that carry nothing to the key, by number. Any other one may hold a report for it.
HIDRAW_READS = frozenset({0x01, 0x02, 0x03, 0x04, 0x05, 0x07, 0x08, 0x0A, 0x0C, 0x0D})
# The task name ahead of the pid is the program's own choice, so the match is anchored on what the kernel prints after it.
SEND_PROBES = {
    "key_write": "hidraw_write rdev=file->f_inode->i_rdev",
    "key_ioctl": "hidraw_ioctl rdev=file->f_inode->i_rdev cmd=cmd",
}
SEND_EVENT = re.compile(r".*-(\d+)\s+\[\d+\]\s+\S+\s+(\d+\.\d+): (key_write|key_ioctl): \(.*\) rdev=(\d+)(?: cmd=(\d+))?\s*$")

# The PAM step waits this long for a notifier that is restarting, as one does during a switch.
NOTIFIER_WAIT = 5.0
ACK_TIMEOUT = 3.0
POLKIT_WAIT = 1.0
PAM_MAX_AGE = 120.0
CONSOLE = re.compile(r"(/dev/)?tty[0-9]+")

TRUSTED_PREFIXES = ("/nix/store/", "/run/wrappers/", "/run/current-system/")
STORE = "/nix/store/"
STORE_HASH = re.compile(r"/nix/store/[0-9a-z]{32}-")
STORE_HASH_BYTES = re.compile(rb"/nix/store/[0-9a-z]{32}-")
STORE_PATH = re.compile(r"/nix/store/[0-9a-z]{32}-[^/]+")
PACKAGE = re.compile(r"[A-Za-z][\w.+-]*?-[0-9][\w.+-]+")
SYSTEM_PROFILE = "/nix/var/nix/profiles/system"
PROFILE_ACTION = "set as the boot default"
MANAGE_UNITS = "org.freedesktop.systemd1.manage-units"
CONFINE_INSTANCE = re.compile(r"/confine/([A-Za-z0-9][\w-]*(?:\.[\w-]+)+)\.[0-9]+/")
MAX_READ = 4 << 20
MAX_LISTED = 6

# Under a system's etc, these decide who gets root, the others only shape what root does.
ROOT_ETC = ("pam.d", "pam", "sudoers", "sudoers.d", "doas.conf", "polkit-1", "security", "environment",
            "ld-nix.so.preload", "ssh")
OTHER_ETC = ("dbus-1", "udev/rules.d", "tmpfiles.d", "sysctl.d", "modprobe.d", "modules-load.d", "fish", "profile",
             "bashrc", "zshenv", "zshrc", "shells", "login.defs", "libvirt/hooks", "systemd/system.conf",
             "systemd/user.conf", "systemd/logind.conf", "systemd/system-generators", "nix/registry.json")
ROOT_PACKAGE_FILES = ("sw/share/polkit-1/rules.d",)
OTHER_PACKAGE_FILES = ("sw/share/dbus-1/system.d", "sw/share/dbus-1/system-services")
NIX_TRUST = ("substituters", "extra-substituters", "trusted-substituters", "extra-trusted-substituters",
             "trusted-public-keys", "extra-trusted-public-keys", "trusted-users", "extra-trusted-users",
             "allowed-users", "extra-allowed-users", "require-sigs", "sandbox", "sandbox-paths", "extra-sandbox-paths",
             "build-users-group", "post-build-hook", "pre-build-hook", "plugin-files", "extra-plugin-files",
             "builders", "secret-key-files", "netrc-file")
PRIVILEGED_GROUPS = {"wheel", "root", "sudo", "admin", "libvirtd", "docker", "podman", "disk", "input", "uinput",
                     "kmem", "tss"}

BROWSERS = {"zen", "zen-bin", "zen-beta", "firefox", "firefox-bin", "firefox-esr", "librewolf", "floorp",
            "chromium", "chrome", "google-chrome", "brave", "vivaldi", "vivaldi-bin"}
SHELLS = {"bash", "sh", "dash", "zsh", "fish", "nu", "ksh"}
INTERPRETER = re.compile(r"(python|perl|ruby|node|lua|luajit|php|deno|bun|tclsh)[0-9.]*")
TERMINALS = {"konsole", "yakuake", "alacritty", "kitty", "foot", "wezterm-gui", "ghostty", "xterm"}
UNLOCKERS = {"kscreenlocker_greet", "kscreenlocker_g", "sddm-helper", "login", "swaylock", "hyprlock", "vlock"}
ROOT_TOOLS = {"passwd", "chsh", "chfn", "chpasswd", "useradd", "userdel", "usermod", "groupadd", "groupdel",
              "groupmod", "groupmems", "runuser", "newgrp", "sg"}

SHELL_VALUE_OPTIONS = {"-C", "--init-command", "--rcfile", "--init-file", "-O", "+O", "-o", "+o",
                       "-D", "--debug-output", "-d", "--debug", "--features", "--profile", "--profile-startup"}
INTERPRETER_INLINE = {"-c", "-e", "-E", "--eval", "-p", "--print", "-m"}
INTERPRETER_VALUE_OPTIONS = {"-W", "-X", "-r", "--require", "--import", "--loader", "--experimental-loader",
                             "--env-file", "--conditions"}
SUDO_VALUE_FLAGS = set("aCcDgpRrTtUu")
SUDO_VALUE_LONG = {"--close-from", "--chdir", "--group", "--host", "--prompt", "--chroot", "--role", "--type",
                   "--command-timeout", "--other-user", "--user"}
SU_VALUE_OPTIONS = {"-c", "--command", "-s", "--shell", "-g", "--group", "-G", "--supp-group",
                    "-w", "--whitelist-environment", "--session-command"}

NO_NOTIFIER = ("touch-guard: no notifier is running in your desktop session, so this root request was refused. "
               "Log in on a text console (Ctrl+Alt+F3) if the desktop cannot run one.")
NOT_SHOWN = "touch-guard: the notification could not be shown, so this root request was refused."


def log(message):
    print(message, flush=True)


def is_fido_descriptor(data):
    """Walks HID report descriptor items looking for the FIDO usage page and the CTAPHID usage."""
    fido = ctaphid = False
    i = 0
    while i < len(data):
        prefix = data[i]
        if prefix == 0xFE:  # long item: size in the next byte
            if i + 1 >= len(data):
                break
            i += 3 + data[i + 1]
            continue
        size = (0, 1, 2, 4)[prefix & 0x03]
        typ = (prefix >> 2) & 0x03
        tag = (prefix >> 4) & 0x0F
        value = int.from_bytes(data[i + 1:i + 1 + size], "little") if size else 0
        if typ == 1 and tag == 0 and value == FIDO_USAGE_PAGE:
            fido = True
        elif typ == 2 and tag == 0 and value == FIDO_USAGE_CTAPHID:
            ctaphid = True
        i += 1 + size
    return fido and ctaphid


def find_fido_devices(sys_root="/sys/class/hidraw", dev_root="/dev"):
    devices = []
    for node in sorted(glob.glob(os.path.join(sys_root, "hidraw*"))):
        try:
            with open(os.path.join(node, "device", "report_descriptor"), "rb") as f:
                if is_fido_descriptor(f.read()):
                    devices.append(os.path.join(dev_root, os.path.basename(node)))
        except OSError:
            continue
    return devices


def frame_kind(report):
    """"wait" when the key asks for a touch, "reply" for any other answer, None for frames that change nothing."""
    if len(report) < 9:
        return None
    cmd = report[4]
    if cmd == CTAPHID_KEEPALIVE:
        return "wait" if report[7] == STATUS_UPNEEDED else None
    if cmd == CTAPHID_MSG and (report[5] << 8 | report[6]) == 2 \
            and (report[7] << 8 | report[8]) == U2F_SW_CONDITIONS_NOT_SATISFIED:
        return "wait"
    # Continuation frames carry a sequence number instead of a command.
    return "reply" if cmd & TYPE_INIT else None


def reply_outcome(report):
    cmd = report[4]
    if cmd == CTAPHID_CBOR:
        return CTAP2_ENDINGS.get(report[7], f"refused, CTAP2 status 0x{report[7]:02x}")
    if cmd == CTAPHID_MSG:
        if (report[5] << 8 | report[6]) != 2:
            return "touched"
        sw = report[7] << 8 | report[8]
        return "touched" if sw == U2F_SW_NO_ERROR else f"refused, U2F status 0x{sw:04x}"
    if cmd == CTAPHID_ERROR:
        return f"error 0x{report[7]:02x}"
    return "answered"


class WaitTracker:
    """Turns one device's frames into touch waits.

    A wait belongs to the channel that asked. A wait from another channel, or a fresh one after a reply,
    starts over with its own requester scan, so a request queued behind a legitimate one never inherits
    the legitimate one's notification.
    """

    def __init__(self):
        self.cid = None
        self.deadline = 0.0
        self.outcome = None
        self.busy = {}
        self.since = 0.0

    def feed(self, report, now):
        """True when the report starts a new wait."""
        kind = frame_kind(report)
        cid = bytes(report[:4])
        # A key may work on a request for a while before it asks for the touch, the request was sent before all of that.
        if len(report) > 4 and report[4] == CTAPHID_KEEPALIVE:
            self.busy = {c: t for c, t in self.busy.items() if now - t < 60}
            self.busy.setdefault(cid, now)
        elif kind == "reply":
            self.busy.pop(cid, None)
        if kind == "wait":
            started = cid != self.cid or self.outcome is not None
            self.cid, self.outcome, self.deadline = cid, None, now + WAIT_GRACE
            if started:
                self.since = self.busy.get(cid, now)
            return started
        if kind == "reply" and cid == self.cid and self.outcome is None:
            self.outcome = reply_outcome(report)
            self.deadline = min(self.deadline, now + REPLY_GRACE)
        return False

    def end(self, now):
        """How the current wait ended once it has, None while it lasts or when there is none."""
        if self.cid is None or now < self.deadline:
            return None
        self.cid = None
        return self.outcome or "keepalives stopped"


def read_text(path, default=""):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return default


def read_link(path):
    try:
        return os.readlink(path)
    except OSError:
        return ""


def program_name(exe, comm):
    name = os.path.basename(exe).removesuffix(" (deleted)") or comm
    # nixpkgs wrappers exec the real program as .name-wrapped.
    while name.startswith(".") and name.endswith("-wrapped"):
        name = name[1:-len("-wrapped")]
    return name


def user_name(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except (KeyError, OverflowError):
        return str(uid)


def proc_info(pid, proc_root="/proc"):
    base = os.path.join(proc_root, str(pid))
    status = {}
    for line in read_text(os.path.join(base, "status")).splitlines():
        key, _, value = line.partition(":")
        status[key] = value.strip()
    if not status:
        return None
    cmdline = read_text(os.path.join(base, "cmdline")).split("\0")
    if cmdline[-1] == "":
        cmdline.pop()
    exe = read_link(os.path.join(base, "exe"))
    # The real uid names the user who ran a setuid tool such as sudo, the effective uid shows it really is one.
    uids = (status.get("Uid", "") + " -1 -1").split()
    return {
        "pid": int(pid),
        "ppid": int(status.get("PPid", "0") or 0),
        "user": user_name(int(uids[0])),
        "euid": int(uids[1]),
        "name": program_name(exe, read_text(os.path.join(base, "comm")).strip()),
        "exe": exe,
        "cmdline": cmdline,
        "cwd": read_link(os.path.join(base, "cwd")),
        "stdin": read_link(os.path.join(base, "fd", "0")),
    }


def chain_of(pid, proc_root="/proc", depth=16):
    chain = []
    seen = set()
    while pid > 1 and pid not in seen and len(chain) < depth:
        seen.add(pid)
        info = proc_info(pid, proc_root)
        if not info:
            break
        chain.append(info)
        pid = info["ppid"]
    return chain


def start_time(pid, proc_root="/proc"):
    """Start time in clock ticks, which tells a process from a later one that reused its pid."""
    text = read_text(os.path.join(proc_root, str(pid), "stat"))
    fields = text.rpartition(")")[2].split()
    return fields[19] if len(fields) > 19 else None


def key_value_lines(text):
    pairs = {}
    for line in text.splitlines():
        key, _, value = line.partition(":")
        pairs[key] = value.strip()
    return pairs


def mount_devices(pid_dir):
    """Mount id to the major:minor of its filesystem, as the process's mount namespace lists them."""
    mounts = {}
    for line in read_text(os.path.join(pid_dir, "mountinfo")).splitlines():
        fields = line.split(" ", 3)
        if len(fields) > 2:
            mounts[fields[0]] = fields[2]
    return mounts


def holders_of(device, proc_root="/proc", exclude=()):
    """Pids with the device open.

    Matches inode and filesystem through fdinfo and mountinfo and never stats the open file itself:
    a stat of a FUSE file waits on its server, so a hostile FUSE mount could stall the scan forever.
    """
    try:
        st = os.stat(device)
    except OSError:
        return []
    want_dev = f"{os.major(st.st_dev)}:{os.minor(st.st_dev)}"
    want_ino = str(st.st_ino)
    init_mounts = None
    pids = []
    for entry in os.listdir(proc_root):
        if not entry.isdigit() or int(entry) in exclude:
            continue
        base = os.path.join(proc_root, entry)
        try:
            fds = os.listdir(os.path.join(base, "fd"))
        except OSError:
            continue
        mounts = None
        for fd in fds:
            if not read_link(os.path.join(base, "fd", fd)).startswith("/"):
                continue
            info = key_value_lines(read_text(os.path.join(base, "fdinfo", fd)))
            if info.get("ino") != want_ino:
                continue
            if mounts is None:
                mounts = mount_devices(base)
            dev = mounts.get(info.get("mnt_id"))
            if dev is None:
                if init_mounts is None:
                    init_mounts = mount_devices(os.path.join(proc_root, "1"))
                dev = init_mounts.get(info.get("mnt_id"))
            # A mount nobody lists any more still counts: an extra requester is safer than a hidden one.
            if dev in (want_dev, None):
                pids.append(int(entry))
                break
    return pids


def kernel_dev(device):
    """The device number as the kernel holds it in an inode, None when the node is gone."""
    try:
        rdev = os.stat(device).st_rdev
    except OSError:
        return None
    return os.major(rdev) << 20 | os.minor(rdev)


class SendTrace:
    """Which programs sent something to a security key, from kernel probes on the two calls a program can send through.

    A program that only holds the key open sends nothing, which tells it apart from the one that made the key blink.
    Whenever that cannot be told for sure (no probes, lost events, a sender that is already gone) the answer is
    None, and every program holding the key is named as before.
    """

    def __init__(self, root=TRACING, proc_root="/proc"):
        self.root = root
        self.proc_root = proc_root
        self.instance = os.path.join(root, "instances", "touch-guard")
        self.pipe = None
        self.pending = b""
        self.keys = None
        self.sent = collections.deque(maxlen=4096)
        self.unsure = 0.0
        self.lost = None
        self.checked = 0.0

    @staticmethod
    def write(path, text):
        try:
            # Not open(path, "a"): Python then seeks to the end, which these kernel files refuse.
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                os.write(fd, text.encode() + b"\n")
            finally:
                os.close(fd)
        except OSError as e:
            # A failed write names no file by itself, and which setting the kernel refused is the whole answer.
            raise OSError(e.errno, f"{e.strerror}, writing {text!r} to {path}") from None

    def open(self):
        events = os.path.join(self.root, "dynamic_events")
        group = os.path.join(self.instance, "events", "touchguard")
        os.makedirs(self.instance, exist_ok=True)
        defined = read_text(events).splitlines()
        for name, probe in SEND_PROBES.items():
            line = f"p:touchguard/{name} {probe}"
            if line in defined:
                continue
            if any(d.startswith(f"p:touchguard/{name} ") for d in defined):
                self.write(os.path.join(group, name, "enable"), "0")
                self.write(events, f"-:touchguard/{name}")
            self.write(events, line)
        self.write(os.path.join(self.instance, "trace_clock"), "mono")
        self.write(os.path.join(self.instance, "buffer_size_kb"), "64")
        self.filter()
        self.write(os.path.join(group, "enable"), "1")
        self.pipe = os.open(os.path.join(self.instance, "trace_pipe"), os.O_RDONLY | os.O_NONBLOCK)

    def filter(self):
        wanted = " || ".join(f"rdev == {dev}" for dev in sorted(self.keys or ())) or "rdev == 0"
        for name in SEND_PROBES:
            self.write(os.path.join(self.instance, "events", "touchguard", name, "filter"), wanted)

    def watch(self, devices):
        """Follows these device nodes. Probes are set up with the first key, when the driver they sit in is loaded."""
        keys = {dev for dev in map(kernel_dev, devices) if dev is not None}
        if keys == self.keys:
            return
        self.keys = keys
        try:
            if self.pipe is None:
                if keys:
                    self.open()
                    log("following which programs send to a security key")
            else:
                self.filter()
        except OSError as e:
            log(f"cannot follow which programs send to a security key ({e}), every program holding one is named")
            self.close()

    def close(self):
        if self.pipe is not None:
            os.close(self.pipe)
        self.pipe = None

    def tgid(self, tid):
        return int(key_value_lines(read_text(os.path.join(self.proc_root, str(tid), "status"))).get("Tgid", 0)) or None

    def losses(self):
        total = 0
        for path in glob.glob(os.path.join(self.instance, "per_cpu", "cpu*", "stats")):
            stats = key_value_lines(read_text(path))
            total += int(stats.get("overrun", 0)) + int(stats.get("dropped events", 0))
        return total

    def drain(self, now):
        if self.pipe is None:
            return
        try:
            while chunk := os.read(self.pipe, 65536):
                self.pending += chunk
        except BlockingIOError:
            pass
        except OSError as e:
            log(f"stopped following which programs send to a security key: {e}")
            self.close()
            return
        *lines, self.pending = self.pending.split(b"\n")
        for raw in lines:
            line = raw.decode(errors="replace")
            event = SEND_EVENT.match(line)
            if not event:
                if "key_write" in line or "key_ioctl" in line or "LOST" in line:
                    self.unsure = now + SEND_WINDOW
                continue
            tid, stamp, name, rdev, cmd = event.groups()
            if name == "key_ioctl" and ((int(cmd) >> 8 & 0xFF) != ord("H") or int(cmd) & 0xFF in HIDRAW_READS):
                continue
            self.sent.append((float(stamp), int(rdev), self.tgid(int(tid))))
        if now - self.checked >= 1.0:
            self.checked = now
            lost = self.losses()
            if self.lost is not None and lost != self.lost:
                self.unsure = now + SEND_WINDOW
            self.lost = lost

    def senders(self, device, since, now):
        """Pids that sent to the device from `since` on, None when that is not known for sure."""
        self.drain(now)
        dev = kernel_dev(device)
        if self.pipe is None or dev is None or since <= self.unsure:
            return None
        pids = {pid for stamp, rdev, pid in self.sent if rdev == dev and stamp >= since}
        return None if None in pids else pids


def notifier_problem(pid, uid, argv, proc_root="/proc"):
    """Why the process on the other end of the event socket is not the system's own notifier, None when it is."""
    base = os.path.join(proc_root, str(pid))
    status = key_value_lines(read_text(os.path.join(base, "status")))
    if not status:
        return "it is gone"
    if status.get("Uid", "").split()[:1] != [str(uid)]:
        return "it runs as another user"
    if status.get("TracerPid", "0") != "0":
        return "another process traces it"
    if read_link(os.path.join(base, "exe")) != os.path.realpath(argv[0]):
        return "it runs another program"
    if read_text(os.path.join(base, "cmdline")).split("\0")[:-1] != argv:
        return "it was started with other arguments"
    loader = sorted({e.split("=", 1)[0] for e in read_text(os.path.join(base, "environ")).split("\0")
                     if e.startswith(("LD_", "GCONV_PATH="))})
    if loader:
        return "its environment sets " + ", ".join(loader)
    # A unit drop-in can bind other files over the store inside a namespace of its own.
    for ns in ("mnt", "user"):
        if read_link(os.path.join(base, "ns", ns)) != read_link(os.path.join(proc_root, "1", "ns", ns)):
            return f"it runs in its own {ns} namespace"
    return None


def shorten(text, limit=160):
    # Store hashes mean nothing to a reader and push the command out of view; the journal keeps the full exe.
    text = STORE_HASH.sub("/nix/store/…-", text)
    return text if len(text) <= limit else text[:limit - 1] + "…"


def short(argv):
    return shorten(shlex.join(argv)) if argv else ""


def listed(items, limit=MAX_LISTED):
    items = list(items)
    text = ", ".join(items[:limit])
    return text + (f" (+{len(items) - limit} more)" if len(items) > limit else "")


def is_interpreter(name):
    return name in SHELLS or INTERPRETER.fullmatch(name) is not None


def script_of(p):
    """What a shell or interpreter runs: ("path", file) or ("inline", text), None when it is interactive."""
    name, args = p["name"], p["cmdline"][1:]
    shell = name in SHELLS
    values = SHELL_VALUE_OPTIONS if shell else INTERPRETER_VALUE_OPTIONS
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            i += 1
            break
        if a == "-" or not a.startswith(("-", "+")):
            break
        inline = (a == "--command" or (not a.startswith("--") and "c" in a[1:])) if shell else a in INTERPRETER_INLINE
        if inline:
            return "inline", shorten(shlex.join([name] + args[i:i + 2]), 100)
        i += 2 if a in values else 1
    if i < len(args) and args[i] != "-":
        path = args[i]
        if not path.startswith("/") and p["cwd"]:
            path = os.path.normpath(os.path.join(p["cwd"], path))
        return "path", path
    # Without a script operand a shell reads commands from stdin, which only a person types into on a terminal.
    if p["stdin"].startswith(("/dev/pts/", "/dev/tty")):
        return None
    source = "piped commands" if p["stdin"].startswith("pipe:") else p["stdin"] or "unknown input"
    return "inline", f"{name} reading {source}"


def launch_warning(processes, need_terminal):
    """Warns when nobody typed the request in a terminal: direnv, a script or inline code sits above it, or
    for tools that act as root, no interactive shell does."""
    scripts, direnv, from_terminal = [], None, False
    for p in processes:
        name = p["name"]
        if name == "direnv":
            direnv = direnv or p
        elif name in TERMINALS:
            from_terminal = True
            break
        elif is_interpreter(name):
            script = script_of(p)
            if script is None:
                from_terminal = True
                break
            kind, text = script
            if kind == "inline" or not text.startswith(TRUSTED_PREFIXES):
                scripts.append(text)
    if direnv:
        return "started by direnv, from the .envrc in " + (direnv["cwd"] or "?")
    if scripts:
        return "started by " + scripts[0]
    if need_terminal and not from_terminal:
        parent = processes[0]["name"] if processes else "systemd"
        return f"started by {parent}, not from a terminal"
    return None


def describe_chain(processes):
    parts = []
    for p in processes[:4]:
        script = script_of(p) if is_interpreter(p["name"]) else None
        if script and script[0] == "path":
            parts.append(f"{p['name']} {os.path.basename(script[1])}")
        else:
            parts.append(p["name"])
    return " ← ".join(parts)


def sandbox_of(processes):
    """The confine app id when a request comes through one of its D-Bus proxies."""
    for p in processes:
        for arg in p["cmdline"]:
            m = CONFINE_INSTANCE.search(arg)
            if m:
                return m.group(1)
    return None


def parse_sudo(argv):
    """sudo's options and the command after them, following its getopt rules."""
    opts, i = {}, 1
    while i < len(argv):
        a = argv[i]
        if a == "--":
            i += 1
            break
        if not a.startswith("-") or a == "-":
            break
        if a.startswith("--"):
            key, eq, value = a.partition("=")
            if not eq and key in SUDO_VALUE_LONG and i + 1 < len(argv):
                i += 1
                value = argv[i]
            opts[key] = value
        else:
            for j, flag in enumerate(a[1:], 2):
                if flag in SUDO_VALUE_FLAGS:
                    value = a[j:]
                    if not value and i + 1 < len(argv):
                        i += 1
                        value = argv[i]
                    opts["-" + flag] = value
                    break
                opts["-" + flag] = ""
        i += 1
    return opts, argv[i:]


def system_name(path):
    return path.split(STORE, 1)[-1].split("/", 1)[0].split("-", 1)[-1]


def rebuild_target(command):
    """The NixOS system a root command activates and what it does with it, or None."""
    for i, a in enumerate(command):
        if a.endswith("/bin/switch-to-configuration"):
            return a[:-len("/bin/switch-to-configuration")], command[i + 1] if i + 1 < len(command) else ""
        if os.path.basename(a) == "nixos-activate" and i + 1 < len(command):
            return command[i + 1], command[i + 2] if i + 2 < len(command) else "switch"
    if any(a == SYSTEM_PROFILE or a.endswith("/profiles/system") for a in command):
        systems = [a for a in command if STORE_PATH.fullmatch(a)]
        if systems:
            return systems[-1], PROFILE_ACTION
    return None


def rebuild_note(command):
    target = rebuild_target(command)
    if not target:
        return None
    system, action = target
    if action == PROFILE_ACTION:
        return f"NixOS rebuild: set the boot system profile ({system_name(system)})"
    if os.path.basename(command[0]) == "nixos-activate":
        return f"NixOS rebuild: {action} ({system_name(system)})"
    return f"NixOS rebuild: switch-to-configuration {action} ({system_name(system)})"


def split_env(command):
    """The program an env invocation runs, and the names of the variables it sets for it."""
    if not command or os.path.basename(command[0]) != "env":
        return command, []
    names, i = [], 1
    while i < len(command):
        a = command[i]
        if a == "--":
            i += 1
            break
        if a in ("-u", "--unset", "-C", "--chdir", "-S", "--split-string"):
            i += 2
        elif a.startswith("-"):
            i += 1
        elif "=" in a:
            names.append(a.split("=", 1)[0])
            i += 1
        else:
            break
    return command[i:], names


def sudo_program(argv):
    """The program a sudo invocation runs as root, without the env in front of it."""
    return split_env(parse_sudo(argv)[1])[0]


def describe_sudo(argv):
    opts, command = parse_sudo(argv)
    target = opts.get("-u") or opts.get("--user") or "root"
    title = f"sudo (runs as {target})"
    if "-v" in opts or "--validate" in opts:
        return title, ["sudo -v: checks your login, which sudo may then remember for later calls from this terminal"]
    if "-e" in opts or "--edit" in opts or (argv and os.path.basename(argv[0]) == "sudoedit"):
        return title, [f"edit as {target}: {short(command)}"]
    if not command:
        if any(k in opts for k in ("-i", "-s", "--login", "--shell")):
            return title, [f"opens a {target} shell"]
        return title, [short(argv)]
    program, env_names = split_env(command)
    if not program:
        return title, [short(command)]
    # Variable names stay visible, since env A=B runs as root too (LD_PRELOAD would matter), but their values
    # (a whole PATH, for nh) would hide the command.
    shown = short(program) + (f" (env sets {', '.join(env_names)})" if env_names else "")
    note = rebuild_note(program)
    return title, ([note] if note else []) + [shown]


def describe_unit(unit):
    """A transient unit someone asked systemd to start, as run0 and systemd-run do."""
    tool = "run0" if unit["description"].startswith("[run0]") else "systemd-run"
    title = f"{tool} (runs as {unit['user'] or 'root'})"
    note = rebuild_note(unit["argv"]) if unit["argv"] else None
    return title, ([note] if note else []) + [short(unit["argv"]) or unit["name"]]


def first_operand(argv, value_options, default):
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--":
            return argv[i + 1] if i + 1 < len(argv) else default
        if not a.startswith("-"):
            return a
        i += 2 if a in value_options else 1
    return default


def option_value(argv, flag):
    i = argv.index(flag) if flag in argv else -1
    return argv[i + 1] if 0 <= i < len(argv) - 1 else ""


def classify(p, parents):
    """Title, detail lines, and whether a person should have started it from a terminal."""
    name, argv = p["name"], p["cmdline"]
    if name == "sudo":
        title, lines = describe_sudo(argv)
        return title, lines, True
    if name == "su":
        return f"su (switches to {first_operand(argv, SU_VALUE_OPTIONS, 'root')})", [short(argv)], True
    if name in ROOT_TOOLS:
        return f"{name} (runs as root)", [short(argv)], True
    if name in UNLOCKERS:
        return "login or screen unlock", [short(argv)], False
    if name == "ssh-keygen" and "-Y" in argv and "sign" in argv:
        key = option_value(argv, "-f")
        lines = ["key " + os.path.basename(key)] if key else [short(argv)]
        git = next((q for q in parents if q["name"] == "git"), None)
        if git:
            return "git signing", lines + [short(git["cmdline"])], False
        return "SSH signature", lines, False
    if name == "ssh-keygen":
        return "SSH security key setup", [short(argv)], False
    if name in ("ssh", "scp", "sftp"):
        return "SSH login" if name == "ssh" else "SSH file transfer", [short(argv)], False
    if name == "ssh-agent":
        return "SSH key use through ssh-agent", ["the program that asked the agent is unknown"], False
    if name in BROWSERS:
        return "browser login or passkey", ["the site is named in the browser's own dialog"], False
    return name or "unknown program", [short(argv) or p["exe"]], False


def polkit_lines(entry):
    if not entry:
        return ["action unknown, read the details in the KDE dialog"]
    details = entry["details"]
    lines = [f"{entry['message'] or entry['action']} ({entry['action']})"]
    command = details.get("command_line") or details.get("program")
    if command:
        lines.append(command)
    extra = ", ".join(f"{k}={v}" for k, v in sorted(details.items())
                      if not k.startswith("polkit.") and k not in ("command_line", "program"))
    if extra:
        lines.append(extra)
    return [shorten(line) for line in lines]


def polkit_subject(entry, proc_root):
    pid = entry["details"].get("polkit.subject-pid", "") if entry else ""
    return chain_of(int(pid), proc_root) if pid.isdigit() else []


def describe_request(chain, polkit, proc_root, context=None):
    holder = chain[0]
    polkit_helper = holder["name"].startswith("polkit-agent-he")
    # Anyone can nix build a program named sudo into the store, but only the real one runs as root.
    impostor = (polkit_helper or holder["name"] in ROOT_TOOLS | {"sudo", "su"}) and holder["euid"] != 0
    command = None
    if impostor:
        subject, processes = holder, chain[1:]
        title, lines, need_terminal = holder["name"], [short(holder["cmdline"]) or holder["exe"]], False
    elif polkit_helper:
        # The helper only runs PAM for polkit, so the requester is polkit's subject, not a helper ancestor.
        processes = polkit_subject(polkit, proc_root) or chain[1:]
        subject = processes[0] if processes else holder
        unit = None
        if context and polkit and polkit["action"] == MANAGE_UNITS:
            unit = context.transient(subject["pid"])
        if unit:
            title, lines = describe_unit(unit)
            command = unit["argv"]
        else:
            title, lines = "admin rights (polkit)", polkit_lines(polkit)
        need_terminal = False
    else:
        if holder["name"] == "ssh-sk-helper" and len(chain) > 1:
            chain = chain[1:]
        subject, processes = chain[0], chain[1:]
        title, lines, need_terminal = classify(subject, processes)
        if subject["name"] == "sudo":
            command = sudo_program(subject["cmdline"])
    warnings = [f"calls itself {holder['name']} but does not run as root, so it is not the real one"] if impostor else []
    for p in (holder, subject):
        warning = "not from your system: " + p["exe"]
        if p["exe"] and not p["exe"].startswith(TRUSTED_PREFIXES) and warning not in warnings:
            warnings.append(warning)
    target = rebuild_target(command) if command and context else None
    if target:
        changes, risky = context.diff(target[0])
        lines = lines[:1] + changes + lines[1:]
        warnings.extend(risky)
    sandbox = sandbox_of([subject] + processes)
    if sandbox:
        lines.append(f"asked from inside the {sandbox} sandbox")
    launch = launch_warning(processes, need_terminal)
    if launch:
        warnings.append(launch)
    return {
        "pid": subject["pid"],
        "holder": holder["pid"],
        "user": subject["user"],
        "title": title,
        "lines": lines,
        "exe": subject["exe"],
        "cwd": subject["cwd"],
        "chain": describe_chain(processes),
        "warnings": warnings,
    }


def report_for(device, proc_root, exclude, polkit, context=None, senders=None):
    """`senders` are the pids known to have sent to the key for this wait, None when that is not known."""
    holders = {}
    for pid in list(holders_of(device, proc_root, exclude)) + sorted((senders or set()) - set(exclude)):
        info = proc_info(pid, proc_root)
        if info:
            holders[pid] = info
    idle = []
    # With nobody seen sending the key should not be waiting at all, so everyone holding it stays named.
    if senders and any(pid in holders for pid in senders):
        idle = [info for pid, info in holders.items() if pid not in senders]
        holders = {pid: info for pid, info in holders.items() if pid in senders}
    requesters = []
    for pid in holders:
        chain = chain_of(pid, proc_root)
        # A child that inherited or reopened the key under another holder is part of that holder's request.
        if not chain or any(p["pid"] in holders for p in chain[1:]):
            continue
        requesters.append(describe_request(chain, polkit, proc_root, context))
    warnings = []
    if not requesters:
        warnings.append("no program has the key open, don't touch unless you just started something")
    if len(requesters) > 1:
        warnings.append(f"{len(requesters)} requests at once, don't touch")
    return {"device": device, "requesters": requesters, "warnings": warnings, "idle": idle}


def summary_line(report):
    parts = []
    for r in report["requesters"]:
        warnings = "".join(" | WARNING " + w for w in r["warnings"])
        parts.append(f"{r['title']} | {' / '.join(r['lines'])} | pid {r['pid']} user {r['user']} exe {r['exe'] or '?'}"
                     f" | from {r['chain'] or '?'} | in {r['cwd'] or '?'}{warnings}")
    parts.extend("WARNING " + w for w in report["warnings"])
    return " || ".join(parts)


def plain_text(report):
    """The description for a text console, where no notification can show it."""
    out = []
    for r in report["requesters"]:
        out.append(f"touch-guard: {r['title']}")
        out.extend(f"  WARNING {w}" for w in r["warnings"])
        out.extend(f"  {line}" for line in r["lines"])
        out.append(f"  from {r['chain'] or 'unknown'}, pid {r['pid']}")
    return "\n".join(out)


def store_resolve(path, hops=40):
    """path with its links resolved, or None once it leaves the store.

    Links are read one component at a time and never followed outside /nix/store: anywhere else could hold a
    FUSE file whose stat hangs forever, and a system consists of nothing but store paths.
    """
    path = os.path.normpath(path)
    if not path.startswith(STORE):
        return None
    pending = path.split("/")[1:]
    resolved = ""
    while pending:
        current = f"{resolved}/{pending.pop(0)}"
        try:
            target = os.readlink(current)
        except OSError:
            resolved = current
            continue
        hops -= 1
        target = os.path.normpath(os.path.join(resolved or "/", target))
        if hops < 0 or not target.startswith(STORE):
            return None
        pending = target.split("/")[1:] + pending
        resolved = ""
    return resolved


def read_store(path, limit=MAX_READ):
    real = store_resolve(path)
    if real is None:
        return None
    try:
        with open(real, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                return None
            return f.read(limit)
    except OSError:
        return None


def existing(path):
    real = store_resolve(path)
    return real if real and os.path.lexists(real) else None


def digest(data):
    if data is None:
        return None
    return hashlib.sha256(STORE_HASH_BYTES.sub(b"/nix/store/-", data)).hexdigest()[:16]


def store_tree(path, limit=5000):
    """Relative path to content digest for every file under a store path, or {"": digest} for a single file."""
    root = store_resolve(path)
    if root is None:
        return {}
    if not os.path.isdir(root):
        return {"": digest(read_store(root))} if os.path.lexists(root) else {}
    files, stack, seen = {}, [(root, "")], set()
    while stack and len(files) < limit:
        directory, prefix = stack.pop()
        if directory in seen:
            continue
        seen.add(directory)
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in names:
            real = store_resolve(os.path.join(directory, name))
            if real is None:
                files[prefix + name] = "outside the store: " + read_link(os.path.join(directory, name))
            elif os.path.isdir(real):
                stack.append((real, prefix + name + "/"))
            else:
                files[prefix + name] = digest(read_store(real))
    return files


def files_under(system, entries):
    files = {}
    for entry in entries:
        for rel, value in store_tree(f"{system}/{entry}").items():
            files[f"{entry}/{rel}" if rel else entry] = value
    return files


def compare(old, new):
    added = sorted(k for k in new if k not in old)
    removed = sorted(k for k in old if k not in new)
    changed = sorted(k for k in new if k in old and new[k] != old[k])
    return added, removed, changed


def changes_text(old, new, strip=""):
    added, removed, changed = compare(old, new)
    names = [c.removeprefix(strip) for c in changed]
    names += ["+" + a.removeprefix(strip) for a in added] + ["-" + r.removeprefix(strip) for r in removed]
    return listed(names) if names else None


def unit_state(system, kind):
    """Unit files with their drop-ins, and the units another one pulls in at start."""
    units, pulled = {}, {}
    for rel, value in store_tree(f"{system}/etc/systemd/{kind}").items():
        head, _, rest = rel.partition("/")
        if rest and head.endswith((".wants", ".requires", ".upholds")):
            pulled[f"{rest} by {head.rsplit('.', 1)[0]}"] = "yes"
        else:
            name = head.removesuffix(".d") if rest else head
            units.setdefault(name, []).append(f"{rel}={value}")
    return {n: "|".join(sorted(v)) for n, v in units.items()}, pulled


def wrappers(system):
    """Each setuid or capability wrapper's install lines, with store hashes left out."""
    unit = read_store(f"{system}/etc/systemd/system/suid-sgid-wrappers.service") or b""
    m = re.search(rb"^ExecStart=[@!+:-]*(" + re.escape(STORE.encode()) + rb"\S+)", unit, re.MULTILINE)
    script = (read_store(m.group(1).decode()) or b"").decode(errors="replace") if m else ""
    blocks = {}
    for line in script.splitlines():
        m = re.search(r'"\$wrapperDir/([^"/]+)"', line)
        if m and not line.lstrip().startswith("#"):
            name = m.group(1).removesuffix(".real")
            blocks.setdefault(name, []).append(STORE_HASH.sub("/nix/store/…-", line.strip()))
    return {name: "\n".join(lines) for name, lines in blocks.items()}


def accounts(system):
    """Users and groups the activation creates, with password settings reduced to a digest."""
    script = read_store(f"{system}/activate") or b""
    m = re.search(re.escape(STORE.encode()) + rb"[0-9a-z]{32}-users-groups\.json", script)
    try:
        data = json.loads(read_store(m.group().decode()) or b"{}") if m else {}
    except ValueError:
        data = {}
    users, groups = {}, {}
    for u in data.get("users") or []:
        secret = json.dumps([u.get(k) for k in ("hashedPassword", "password", "initialPassword",
                                                 "initialHashedPassword", "hashedPasswordFile")])
        users[str(u.get("name"))] = {"uid": u.get("uid"), "shell": u.get("shell"), "secret": digest(secret.encode())}
    for g in data.get("groups") or []:
        groups[str(g.get("name"))] = sorted(str(m) for m in g.get("members") or [])
    return users, groups


def account_changes(old, new):
    (old_users, old_groups), (new_users, new_groups) = accounts(old), accounts(new)
    risky, other = [], []
    for name in sorted(set(new_users) - set(old_users)):
        (risky if new_users[name]["uid"] == 0 else other).append(f"new user {name}")
    for name in sorted(set(old_users) - set(new_users)):
        other.append(f"user {name} removed")
    for name in sorted(set(new_users) & set(old_users)):
        before, after = old_users[name], new_users[name]
        if after["uid"] != before["uid"]:
            (risky if after["uid"] == 0 else other).append(f"{name} uid {before['uid']} → {after['uid']}")
        if after["secret"] != before["secret"]:
            (risky if name == "root" else other).append(f"{name} password setting")
        if after["shell"] != before["shell"]:
            other.append(f"{name} shell")
    for group in sorted(set(old_groups) | set(new_groups)):
        before, after = set(old_groups.get(group, [])), set(new_groups.get(group, []))
        if before != after:
            members = [f"+{m}" for m in sorted(after - before)] + [f"-{m}" for m in sorted(before - after)]
            (risky if group in PRIVILEGED_GROUPS else other).append(f"{group} {' '.join(members)}")
    return risky, other


def nix_settings(system):
    settings = {}
    for line in (read_store(f"{system}/etc/nix/nix.conf") or b"").decode(errors="replace").splitlines():
        key, eq, value = line.split("#", 1)[0].partition("=")
        if eq:
            settings[key.strip()] = value.split()
    return settings


def nix_changes(old, new):
    before, after = nix_settings(old), nix_settings(new)
    trust, other = [], []
    for key in sorted(set(before) | set(after)):
        if before.get(key) == after.get(key):
            continue
        if key in NIX_TRUST:
            old_values, new_values = before.get(key, []), after.get(key, [])
            diff = [f"+{v}" for v in new_values if v not in old_values] + [f"-{v}" for v in old_values if v not in new_values]
            trust.append(f"{key} {' '.join(diff) or 'reordered'}")
        else:
            other.append(key)
    return trust, other


def kernel_changes(old, new):
    risky, other = [], []
    before = set((read_store(f"{old}/kernel-params") or b"").decode(errors="replace").split())
    after = set((read_store(f"{new}/kernel-params") or b"").decode(errors="replace").split())
    if before != after:
        risky.append("changes kernel parameters: " + listed([f"+{p}" for p in sorted(after - before)]
                                                            + [f"-{p}" for p in sorted(before - after)]))
    kernels = [existing(f"{s}/kernel") or "" for s in (old, new)]
    if kernels[0] != kernels[1]:
        names = [system_name(k) for k in kernels]
        other.append(f"kernel {names[0]} → {names[1]}" if names[0] != names[1] else f"kernel {names[1]} rebuilt")
    for entry, label in (("initrd", "initrd"), ("kernel-modules", "kernel modules")):
        if existing(f"{old}/{entry}") != existing(f"{new}/{entry}"):
            other.append(f"{label} changed")
    return risky, other


def package_names(paths):
    names = {}
    for path in paths:
        name = path[len(STORE) + 33:] if path.startswith(STORE) else path
        if PACKAGE.fullmatch(name) and not name.startswith("nixos-system-"):
            names.setdefault(name, set()).add(path)
    return names


def system_changes(new, old, closure):
    """What activating new instead of the running old system changes in root's reach: (lines, warnings)."""
    if new == old:
        return ["this is the system that already runs"], []
    if not os.path.exists(f"{new}/bin/switch-to-configuration"):
        return [], ["the rebuild names something that is not a NixOS system: " + shorten(new)]
    lines, warnings = [], []
    versions = [(read_store(f"{s}/nixos-version", 200) or b"?").decode(errors="replace").strip() for s in (old, new)]
    if versions[0] != versions[1]:
        lines.append(f"nixpkgs {versions[0]} → {versions[1]}, its updates can hide other package changes")

    root_files = changes_text(files_under(old, [f"etc/{e}" for e in ROOT_ETC] + list(ROOT_PACKAGE_FILES)),
                              files_under(new, [f"etc/{e}" for e in ROOT_ETC] + list(ROOT_PACKAGE_FILES)), "etc/")
    if root_files:
        warnings.append("changes root access config: " + root_files)
    trust, nix_other = nix_changes(old, new)
    if trust:
        warnings.append("changes what Nix trusts: " + listed(trust))
    wrapper_changes = changes_text(wrappers(old), wrappers(new))
    if wrapper_changes:
        warnings.append("changes setuid wrappers: " + wrapper_changes)
    risky_accounts, other_accounts = account_changes(old, new)
    if risky_accounts:
        warnings.append("changes accounts: " + listed(risky_accounts))
    risky_kernel, other_kernel = kernel_changes(old, new)
    warnings.extend(risky_kernel)

    for kind, label in (("system", "system units"), ("user", "user units")):
        (old_units, old_pulled), (new_units, new_pulled) = unit_state(old, kind), unit_state(new, kind)
        text = changes_text(old_units, new_units)
        if text:
            lines.append(f"{label}: {text}")
        pulled = changes_text(old_pulled, new_pulled)
        if pulled:
            lines.append(f"{label} started by others: {pulled}")
    other_files = changes_text(files_under(old, [f"etc/{e}" for e in OTHER_ETC] + list(OTHER_PACKAGE_FILES)),
                               files_under(new, [f"etc/{e}" for e in OTHER_ETC] + list(OTHER_PACKAGE_FILES)), "etc/")
    if other_files:
        lines.append("other root config: " + other_files)
    if nix_other:
        lines.append("other nix.conf settings: " + listed(nix_other))
    if other_accounts:
        lines.append("accounts: " + listed(other_accounts))
    lines.extend(other_kernel)

    if versions[0] == versions[1]:
        try:
            before, after = package_names(closure(old)), package_names(closure(new))
        except (OSError, subprocess.SubprocessError) as e:
            lines.append(f"packages not compared: {e}")
        else:
            rebuilt = sorted(n for n in after if n in before and after[n] != before[n])
            if rebuilt:
                lines.append("rebuilt at the same version: " + listed(rebuilt))
            added = sorted(set(after) - set(before))
            if added:
                lines.append("packages added: " + listed(added))
            removed = sorted(set(before) - set(after))
            if removed:
                lines.append("packages removed: " + listed(removed))
    if not lines and not warnings:
        lines.append("nothing that runs as root changes")
    return lines, warnings


class SystemDiff:
    """Caches system_changes against whatever system runs at the time."""

    def __init__(self, nix_store="nix-store", current="/run/current-system"):
        self.nix_store = nix_store
        self.current = current
        self.lock = threading.Lock()
        self.cache = {}

    def closure(self, system):
        # The service cannot see /root, so nix must not look for configuration there.
        empty = {name: "/var/empty" for name in ("HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "PATH")}
        result = subprocess.run([self.nix_store, "--query", "--requisites", system], capture_output=True, text=True,
                                timeout=30, check=True, env={"NIX_REMOTE": "daemon", **empty})
        return result.stdout.split()

    def __call__(self, system):
        new = store_resolve(system)
        if new is None:
            return [], ["the rebuild names something outside the Nix store: " + shorten(system)]
        old = store_resolve(read_link(self.current)) or ""
        with self.lock:
            if (new, old) not in self.cache:
                started = time.monotonic()
                self.cache = {(new, old): system_changes(new, old, self.closure)}
                log(f"compared {new} with {old} in {time.monotonic() - started:.2f} s: "
                    + " / ".join(self.cache[(new, old)][1] + self.cache[(new, old)][0]))
            return self.cache[(new, old)]


def transient_unit(message):
    """Name, command, user and description of a StartTransientUnit call."""
    data = (message.get("payload") or {}).get("data") or []
    if len(data) < 3 or not isinstance(data[2], list):
        return None
    props = {}
    for item in data[2]:
        if isinstance(item, list) and len(item) == 2 and isinstance(item[1], dict):
            props[str(item[0])] = item[1].get("data")
    argv = []
    for key in ("ExecStart", "ExecStartEx"):
        entries = props.get(key)
        if isinstance(entries, list) and entries and isinstance(entries[0], list) and len(entries[0]) > 1 \
                and isinstance(entries[0][1], list):
            argv = [str(a) for a in entries[0][1]]
            break
    return {"name": str(data[0]), "argv": argv, "user": str(props.get("User") or ""),
            "description": str(props.get("Description") or ""), "time": time.monotonic()}


def bus_pid(name):
    try:
        result = subprocess.run(["busctl", "--system", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
                                 "org.freedesktop.DBus", "GetConnectionUnixProcessID", "s", name],
                                capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    parts = result.stdout.split()
    return int(parts[1]) if result.returncode == 0 and len(parts) == 2 and parts[1].isdigit() else None


class PolkitWatcher:
    """Remembers what polkitd asked the authentication agent to approve, and which transient units were asked for."""

    def __init__(self, pid_of=bus_pid):
        self.lock = threading.Lock()
        self.pending = {}
        self.units = []
        self.pid_of = pid_of

    def handle(self, message):
        if message.get("interface") == "org.freedesktop.systemd1.Manager" \
                and message.get("member") == "StartTransientUnit":
            unit = transient_unit(message)
            if unit:
                unit["pid"] = self.pid_of(str(message.get("sender", "")))
                with self.lock:
                    self.units = self.units[-15:] + [unit]
            return
        if message.get("interface") != "org.freedesktop.PolicyKit1.AuthenticationAgent":
            return
        data = (message.get("payload") or {}).get("data") or []
        if message.get("member") == "BeginAuthentication" and len(data) >= 5:
            with self.lock:
                self.pending[data[4]] = {
                    "action": data[0],
                    "message": data[1],
                    "details": data[3] if isinstance(data[3], dict) else {},
                    "time": time.monotonic(),
                }
        elif message.get("member") == "CancelAuthentication" and data:
            with self.lock:
                self.pending.pop(data[0], None)

    def latest(self, max_age=300):
        """The newest request. Only the newest counts, since a successful authentication is never cancelled."""
        now = time.monotonic()
        with self.lock:
            for cookie in [c for c, p in self.pending.items() if now - p["time"] > max_age]:
                del self.pending[cookie]
            return max(self.pending.values(), key=lambda p: p["time"], default=None)

    def recent(self, max_age, timeout):
        """The newest request from the last max_age seconds, waiting up to timeout for the monitor to report it."""
        deadline = time.monotonic() + timeout
        while True:
            entry = self.latest(max_age)
            if entry or time.monotonic() >= deadline:
                return entry
            time.sleep(0.05)

    def transient(self, pid, max_age=60):
        now = time.monotonic()
        with self.lock:
            for unit in reversed(self.units):
                if unit["pid"] == pid and now - unit["time"] < max_age:
                    return unit
        return None

    def run(self):
        matches = ["type='method_call',interface='org.freedesktop.PolicyKit1.AuthenticationAgent'",
                   "type='method_call',interface='org.freedesktop.systemd1.Manager',member='StartTransientUnit'"]
        command = ["busctl", "monitor", "--system", "--json=short"] + [f"--match={m}" for m in matches]
        while True:
            started = time.monotonic()
            try:
                proc = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
                for line in proc.stdout:
                    try:
                        self.handle(json.loads(line))
                    except (ValueError, TypeError, IndexError, AttributeError):
                        continue
                log(f"bus monitor exited with status {proc.wait()}")
            except OSError as e:
                log(f"bus monitor failed: {e}")
            # A monitor that fails at once fails again, so only one that ran for a while comes back quickly.
            time.sleep(5 if time.monotonic() - started > 60 else 60)


class Broadcaster:
    """JSON-line event stream for the user's notifier, which answers whether each event made it on screen.

    Only the configured uid may connect, and with an expected command line only the system's own notifier.
    """

    def __init__(self, path, allowed_uid, notifier=None, proc_root="/proc"):
        self.path = path
        self.allowed_uid = allowed_uid
        self.notifier = notifier
        self.proc_root = proc_root
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.clients = []
        self.active = {}
        self.outcomes = {}
        self.refused = {}

    def problem(self, pid):
        return notifier_problem(pid, self.allowed_uid, self.notifier, self.proc_root) if self.notifier else None

    def serve(self):
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.path)
        os.chmod(self.path, 0o666)
        server.listen(4)
        while True:
            try:
                conn, _ = server.accept()
            except OSError as e:
                log(f"event socket: {e}")
                time.sleep(1)
                continue
            creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            pid, uid, _ = struct.unpack("3i", creds)
            problem = self.problem(pid) if uid == self.allowed_uid else "it runs as another user"
            if problem:
                if self.refused.get(pid) != problem:
                    log(f"refused a notifier, pid {pid}: {problem}")
                    self.refused = {pid: problem}
                conn.close()
                continue
            # A client that stops reading must not stall the daemon, so a full buffer drops it instead.
            conn.setblocking(False)
            with self.lock:
                if len(self.clients) >= MAX_CLIENTS:
                    self.clients.pop(0)[0].close()
                if self.send(conn, self.active.values()):
                    self.clients.append((conn, pid))
                    threading.Thread(target=self.listen, args=(conn,), daemon=True).start()
                self.changed.notify_all()

    def listen(self, conn):
        """Reads the notifier's answers until it disconnects."""
        buffer = b""
        while True:
            try:
                ready, _, _ = select.select([conn], [], [], 1.0)
                chunk = conn.recv(4096) if ready else None
            except (BlockingIOError, InterruptedError):
                chunk = None
            except (OSError, ValueError):
                chunk = b""
            if chunk is None:
                continue
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    answer = json.loads(line)
                except ValueError:
                    continue
                if isinstance(answer, dict) and answer.get("event") in ("shown", "failed"):
                    with self.lock:
                        self.outcomes[answer.get("id")] = answer["event"]
                        self.changed.notify_all()
        with self.lock:
            self.clients = [(c, p) for c, p in self.clients if c is not conn]
            self.changed.notify_all()
        conn.close()

    @staticmethod
    def send(conn, events):
        try:
            for event in events:
                conn.sendall((json.dumps(event) + "\n").encode())
            return True
        except OSError:
            conn.close()
            return False

    def publish(self, event):
        with self.lock:
            if event["event"] == "waiting":
                self.active[event["id"]] = event
            else:
                self.active.pop(event["id"], None)
                self.outcomes.pop(event["id"], None)
            self.clients = [(c, p) for c, p in self.clients if self.send(c, [event])]
            self.changed.notify_all()

    def wait_for_notifier(self, timeout):
        """True once a genuine notifier is connected, checked again since it could be traced by now."""
        deadline = time.monotonic() + timeout
        with self.lock:
            while True:
                kept = []
                for conn, pid in self.clients:
                    problem = self.problem(pid)
                    if problem:
                        log(f"dropped the notifier, pid {pid}: {problem}")
                        conn.close()
                    else:
                        kept.append((conn, pid))
                self.clients = kept
                remaining = deadline - time.monotonic()
                if self.clients or remaining <= 0:
                    return bool(self.clients)
                self.changed.wait(remaining)

    def wait_shown(self, event_id, timeout):
        deadline = time.monotonic() + timeout
        with self.lock:
            while self.outcomes.get(event_id) is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.changed.wait(remaining)
            return self.outcomes[event_id] == "shown"


class Guard:
    """Answers touch-guard's PAM step: a root request goes ahead only once its description is on screen."""

    def __init__(self, broadcaster, polkit, context, next_id, proc_root="/proc"):
        self.broadcaster = broadcaster
        self.polkit = polkit
        self.context = context
        self.next_id = next_id
        self.proc_root = proc_root
        self.lock = threading.Lock()
        self.active = {}

    def describe(self, request):
        chain = chain_of(request["pid"], self.proc_root)
        if not chain:
            return None
        entry = None
        if chain[0]["name"].startswith("polkit-agent-he"):
            entry = self.polkit.recent(3, POLKIT_WAIT)
        return {"requesters": [describe_request(chain, entry, self.proc_root, self.context)], "warnings": []}

    def decide(self, request):
        """(allow, message for the PAM conversation)."""
        pid = request["pid"]
        report = self.describe(request)
        if report is None:
            return False, "touch-guard: the program asking for root is already gone"
        log(f"{request['service']} request on {request['tty'] or 'no terminal'}: {summary_line(report)}")
        if CONSOLE.fullmatch(request["tty"]):
            return True, plain_text(report)
        if not self.broadcaster.wait_for_notifier(NOTIFIER_WAIT):
            log(f"refused the {request['service']} request from pid {pid}: no notifier is connected")
            return False, NO_NOTIFIER
        event_id = self.next_id()
        with self.lock:
            self.active[pid] = {"id": event_id, "start": start_time(pid, self.proc_root), "time": time.monotonic()}
        self.broadcaster.publish({"event": "waiting", "id": event_id, **report})
        if self.broadcaster.wait_shown(event_id, ACK_TIMEOUT):
            return True, plain_text(report)
        with self.lock:
            self.active.pop(pid, None)
        self.broadcaster.publish({"event": "done", "id": event_id})
        log(f"refused the {request['service']} request from pid {pid}: the notifier did not show it")
        return False, NOT_SHOWN

    def claim(self, report):
        """The PAM event a key wait belongs to, when the one program holding the key already announced itself."""
        if len(report["requesters"]) != 1 or report["warnings"]:
            return None
        with self.lock:
            entry = self.active.get(report["requesters"][0]["holder"])
            return entry["id"] if entry else None

    def forget(self, event_id):
        with self.lock:
            self.active = {pid: e for pid, e in self.active.items() if e["id"] != event_id}

    def sweep(self):
        """Ids of PAM events whose program exited or that are too old to still wait."""
        now = time.monotonic()
        ended = []
        with self.lock:
            for pid, entry in list(self.active.items()):
                if now - entry["time"] > PAM_MAX_AGE or start_time(pid, self.proc_root) != entry["start"]:
                    ended.append(self.active.pop(pid)["id"])
        return ended


def pam_request(raw):
    """The PAM step's request with every field checked, or None."""
    if not isinstance(raw, dict) or not isinstance(raw.get("pid"), int) or raw["pid"] <= 1:
        return None
    request = {"pid": raw["pid"]}
    for key in ("service", "user", "ruser", "tty", "rhost"):
        value = raw.get(key, "")
        request[key] = value[:256] if isinstance(value, str) else ""
    return request


class PamServer:
    """Root only socket for touch-guard's PAM step."""

    def __init__(self, path, guard):
        self.path = path
        self.guard = guard

    def serve(self):
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.path)
        os.chmod(self.path, 0o600)
        server.listen(8)
        while True:
            try:
                conn, _ = server.accept()
            except OSError as e:
                log(f"PAM socket: {e}")
                time.sleep(1)
                continue
            creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            if struct.unpack("3i", creds)[1] != 0:
                conn.close()
                continue
            threading.Thread(target=self.answer, args=(conn,), daemon=True).start()

    def answer(self, conn):
        with conn:
            conn.settimeout(10)
            try:
                with conn.makefile("rb") as stream:
                    request = pam_request(json.loads(stream.readline(8192)))
            except (OSError, ValueError):
                return
            if request is None:
                return
            try:
                allow, message = self.guard.decide(request)
            except Exception as e:  # noqa: BLE001 - any failure must still answer, as a refusal
                log(f"PAM request failed: {e!r}")
                allow, message = False, "touch-guard failed to check this request, so it was refused"
            try:
                conn.sendall((json.dumps({"allow": allow, "message": message}) + "\n").encode())
            except OSError:
                pass


def watch_device(device, events):
    opened = False
    try:
        with open(device, "rb", buffering=0) as f:
            opened = True
            while report := f.read(64):
                events.put(("report", device, report))
    except OSError as e:
        log(f"stopped watching {device}: {e}")
        # A key that cannot be opened would otherwise be retried, and logged, at every scan.
        if not opened:
            time.sleep(30)
    events.put(("gone", device, None))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--user", required=True)
    parser.add_argument("--socket", default="/run/touch-guard/events.sock")
    parser.add_argument("--pam-socket", default="/run/touch-guard/pam.sock")
    parser.add_argument("--notifier-argv", help="JSON file with the notifier's exact command line")
    parser.add_argument("--nix-store", default="nix-store")
    args = parser.parse_args()

    notifier = None
    if args.notifier_argv:
        with open(args.notifier_argv) as f:
            notifier = json.load(f)

    counter = itertools.count(1)
    counter_lock = threading.Lock()

    def next_id():
        with counter_lock:
            return next(counter)

    polkit = PolkitWatcher()
    threading.Thread(target=polkit.run, daemon=True).start()
    context = types.SimpleNamespace(diff=SystemDiff(args.nix_store), transient=polkit.transient)
    broadcaster = Broadcaster(args.socket, pwd.getpwnam(args.user).pw_uid, notifier)
    threading.Thread(target=broadcaster.serve, daemon=True).start()
    guard = Guard(broadcaster, polkit, context, next_id)
    threading.Thread(target=PamServer(args.pam_socket, guard).serve, daemon=True).start()

    events = queue.Queue()
    trackers = {}
    current = {}
    asking = {}
    trace = SendTrace()
    next_scan = 0.0
    exclude = {os.getpid()}
    log("watching for security key touches")

    def announce(device, since, senders, extra=None):
        result = report_for(device, "/proc", exclude, polkit.latest(), context, senders)
        idle = result.pop("idle")
        if idle:
            log(f"holding {device} without sending to it, left out: "
                + ", ".join(f"{p['name']} (pid {p['pid']})" for p in idle))
        if extra:
            result["warnings"].append(extra)
        asking[device] = (since, senders)
        claimed = guard.claim(result)
        if claimed is not None:
            current[device] = claimed
            log(f"touch requested on {device}, as announced through PAM: {summary_line(result)}")
        else:
            current[device] = next_id()
            log(f"touch requested on {device}: {summary_line(result)}")
            broadcaster.publish({"event": "waiting", "id": current[device], **result})

    def finish(device, why):
        asking.pop(device, None)
        if device in current:
            event_id = current.pop(device)
            log(f"touch wait on {device} ended: {why}")
            guard.forget(event_id)
            broadcaster.publish({"event": "done", "id": event_id})

    while True:
        now = time.monotonic()
        if now >= next_scan:
            for device in find_fido_devices():
                if device not in trackers:
                    trackers[device] = WaitTracker()
                    threading.Thread(target=watch_device, args=(device, events), daemon=True).start()
                    log(f"watching {device}")
            trace.watch(list(trackers))
            next_scan = now + 2.0
        try:
            kind, device, report = events.get(timeout=0.1)
        except queue.Empty:
            kind = None
        now = time.monotonic()
        trace.drain(now)
        if kind == "gone":
            trackers.pop(device, None)
            trace.watch(list(trackers))
            finish(device, "key removed")
        elif kind == "report" and device in trackers and trackers[device].feed(report, now):
            finish(device, "a new request took over")
            since = trackers[device].since - SEND_WINDOW
            announce(device, since, trace.senders(device, since, now))
        # A request slipped in on the waiting channel changes no frame the key sends, only who has sent to it.
        for device, (since, known) in list(asking.items()):
            if known is None or device not in current:
                continue
            late = trace.senders(device, since, now)
            if late is None or late - known:
                finish(device, "another program sent to the key")
                announce(device, since, None if late is None else late - known,
                         "sent to the key while it was already waiting, don't touch")
                asking[device] = (since, None if late is None else known | late)
        for device, tracker in trackers.items():
            outcome = tracker.end(now)
            if outcome:
                finish(device, outcome)
        for event_id in guard.sweep():
            if event_id not in current.values():
                broadcaster.publish({"event": "done", "id": event_id})


if __name__ == "__main__":
    sys.exit(main())

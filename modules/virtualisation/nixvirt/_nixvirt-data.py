import argparse
import bisect
import difflib
import fcntl
import fnmatch
import json
import os
import pwd
import re
import shlex
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from contextlib import contextmanager
from datetime import datetime

CONFIG_PATH = sys.argv[1] if len(sys.argv) > 1 else ""
SELF = os.path.abspath(__file__)
ABORTED = 10

RUNS_CODE = "RUNS CODE"
TAMPERED = "SAME SIZE AND DATE, DIFFERENT CONTENT (possible tampering)"
BASIC_DATA = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
REG_SZ, REG_EXPAND_SZ, REG_BINARY = 1, 2, 3
NTFS_META = ("system.ntfs_acl", "system.ntfs_attrib", "system.ntfs_crtime")

BINARY_EXT = {
    "exe", "dll", "sys", "drv", "ocx", "cpl", "scr", "com", "msi", "msp",
    "msix", "appx", "efi", "jar", "pyd", "so", "node", "dp32", "dp64",
    "plw", "p64", "ax", "ko", "appimage",
}
SCRIPT_EXT = {
    "ps1", "psm1", "psd1", "bat", "cmd", "vbs", "vbe", "js", "jse", "mjs",
    "cjs", "wsf", "wsh", "hta", "lnk", "url", "reg", "ahk", "au3", "py",
    "pyw", "pyc", "sh", "lua", "rb", "pl", "idc", "bash", "zsh", "fish",
    "desktop", "service", "timer", "socket", "pth",
}
AUTORUN_NAMES = {
    "desktop.ini", "autorun.inf", ".bashrc", ".bash_profile", ".bash_login", ".profile", ".zshrc",
    ".zprofile", ".zshenv", ".zlogin", ".xprofile", ".xinitrc", ".xsession", ".pam_environment",
}
POSIX_FS = {"ext2", "ext3", "ext4", "btrfs", "xfs"}
LINUX_DATA = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"

# Text that reaches the terminal comes from a guest filesystem, so control and bidi characters are escaped.
UNSAFE = re.compile("[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069\ud800-\udfff]")


def safe(text):
    return UNSAFE.sub(lambda m: "\\x%02x" % ord(m.group()) if ord(m.group()) < 0x100 else "\\u%04x" % ord(m.group()), text)


def die(msg):
    print("nixvirt-data: " + msg, file=sys.stderr)
    sys.exit(1)


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return "%d %s" % (n, unit) if unit == "B" else "%.1f %s" % (n, unit)
        n /= 1024


def seconds(s):
    return "%.1f s" % s if s < 60 else "%dm %02ds" % divmod(round(s), 60)


class Progress:
    # A status line redrawn in place on a terminal while the worker scans. The time left comes from how long the last scan of
    # the same disk took, or else from the current step when the worker reports its size.
    def __init__(self, expected):
        self.tty = sys.stdout.isatty()
        self.expected = expected
        self.start = time.monotonic()
        self.state = ("starting", None, None, self.start)
        self.lock = threading.Lock()
        self.stop = threading.Event()
        if self.tty:
            threading.Thread(target=self.tick, daemon=True).start()

    def __call__(self, step, done=None, total=None):
        with self.lock:
            self.state = (step, done, total, self.state[3] if step == self.state[0] else time.monotonic())
        self.draw()

    def tick(self):
        while not self.stop.wait(0.5):
            self.draw()

    def draw(self):
        if not self.tty:
            return
        with self.lock:
            if self.stop.is_set():
                return
            step, done, total, since = self.state
            now = time.monotonic()
            elapsed = now - self.start
            frac = left = None
            if self.expected and elapsed < self.expected:
                frac, left = elapsed / self.expected, self.expected - elapsed
            elif total:
                frac = done / total
                if done and now - since > 2:
                    left = (now - since) / done * (total - done)
            parts = []
            if frac is not None:
                fill = int(frac * 20)
                parts.append("[%s%s] %3d%%" % ("#" * fill, "-" * (20 - fill), frac * 100))
            whole = lambda s: "%d s" % s if s < 60 else "%dm %02ds" % divmod(round(s), 60)
            parts.append("about %s left" % whole(max(left, 1)) if left else whole(elapsed))
            parts.append(step + (" %s/%s" % (format(done, ","), format(total, ",")) if total else ""))
            line = "  " + "  ".join(parts)
            sys.stdout.write("\r\x1b[K" + line[:shutil.get_terminal_size().columns - 1])
            sys.stdout.flush()

    def close(self):
        self.stop.set()
        if self.tty:
            with self.lock:
                sys.stdout.write("\r\x1b[K")
                sys.stdout.flush()


def parse_size(text):
    m = re.fullmatch(r"(\d+)([KMGT]?)", text.strip().upper())
    if not m:
        die("invalid size: " + text)
    return int(m.group(1)) * 1024 ** "_KMGT".index(m.group(2) or "_")


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        die("%s failed: %s" % (cmd[0], safe(p.stderr.strip())))
    return p.stdout


def ask(text):
    try:
        with open("/dev/tty", "r+") as tty:
            tty.write(text)
            tty.flush()
            line = tty.readline()
    except OSError:
        sys.stdout.write(text)
        sys.stdout.flush()
        line = sys.stdin.readline()
    if not line:
        return None
    return line.strip()


def confirm(text):
    return (ask(text + " [y/N] ") or "").lower() in ("y", "yes")


def pager(text):
    if not sys.stdout.isatty():
        print(text)
        return
    # less runs as root here, so its shell, editor and log commands are disabled.
    subprocess.run(["less", "-FRX"], input=text, text=True, env={**os.environ, "LESSSECURE": "1"})


def parse_selection(text, count):
    if text.strip().lower() == "all":
        return list(range(1, count + 1))
    picked = set()
    for tok in text.replace(",", " ").split():
        m = re.fullmatch(r"(\d+)(?:-(\d+))?", tok)
        if not m:
            return None
        lo, hi = int(m.group(1)), int(m.group(2) or m.group(1))
        if lo < 1 or hi > count or lo > hi:
            return None
        picked.update(range(lo, hi + 1))
    return sorted(picked)


class Disk:
    def __init__(self, dom, spec):
        self.dom = dom
        self.spec = spec
        self.image = spec["image"]
        stem = self.image[:-4] if self.image.endswith(".img") else self.image
        self.revs = stem + ".revs"
        self.work = stem + ".work.img"
        self.restore_tmp = stem + ".restore.img"
        self.newrev = os.path.join(self.revs, ".rev-new.img")
        self.discarded = os.path.join(self.revs, "discarded.img")

    def rev(self, i):
        return os.path.join(self.revs, "rev%d.img" % i)

    def pin(self, name):
        return os.path.join(self.revs, "pin-%s.img" % name)


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def disk_for(cfg, dom):
    spec = cfg["domains"].get(dom)
    if spec is None:
        die("%s has no data disk configured" % dom)
    return Disk(dom, spec)


def guest_config(spec):
    # The block holding carry entries says which system the data disk serves.
    win, lin = spec.get("windows") or {}, spec.get("linux") or {}
    use = lin if lin.get("carry") else win
    return {"carry": use.get("carry") or {}, "userEnv": use.get("userEnv") or {},
            "letter": win.get("letter"), "mountPoint": lin.get("mountPoint")}


def domstate(dom):
    p = subprocess.run(["virsh", "domstate", dom], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else None


def require_off(dom):
    state = domstate(dom)
    if state != "shut off":
        die("%s must be shut off (state: %s)" % (dom, state or "unknown"))


@contextmanager
def locked(dom, tool="nixvirt-data"):
    lockdir = "/run/lock" if os.geteuid() == 0 else tempfile.gettempdir()
    fd = os.open(os.path.join(lockdir, "%s.%s.lock" % (tool, dom)), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            die("another %s operation is running for %s" % (tool, dom))
        yield
    finally:
        os.close(fd)


def reflink(src, dst, keep_times=False):
    cmd = ["cp", "--reflink=always"]
    if keep_times:
        cmd.append("--preserve=timestamps")
    run(cmd + ["--", src, dst])


def match_owner(ref, path):
    st = os.stat(ref)
    os.chmod(path, stat.S_IMODE(st.st_mode))
    if os.geteuid() == 0:
        os.chown(path, st.st_uid, st.st_gid)


def recover(disk):
    if os.path.exists(disk.newrev):
        if os.path.exists(disk.rev(0)):
            os.unlink(disk.newrev)
        else:
            os.replace(disk.newrev, disk.rev(0))
    if os.path.exists(disk.restore_tmp):
        if os.path.exists(disk.image):
            os.unlink(disk.restore_tmp)
        else:
            os.replace(disk.restore_tmp, disk.image)
            print("%s: finished an interrupted restore" % disk.dom)
    if os.path.exists(disk.work):
        os.unlink(disk.work)


def rotate(disk, shift):
    os.makedirs(disk.revs, mode=0o700, exist_ok=True)
    reflink(disk.image, disk.newrev)
    if shift:
        for i in range(disk.spec["keep"] - 1, 0, -1):
            if os.path.exists(disk.rev(i - 1)):
                os.replace(disk.rev(i - 1), disk.rev(i))
    os.replace(disk.newrev, disk.rev(0))


def replace_image(disk, source):
    reflink(source, disk.restore_tmp)
    match_owner(disk.image, disk.restore_tmp)
    os.makedirs(disk.revs, mode=0o700, exist_ok=True)
    os.replace(disk.image, disk.discarded)
    os.replace(disk.restore_tmp, disk.image)


FIEMAP = 0xC020660B
FIEMAP_HDR = struct.Struct("=QQIIII")
FIEMAP_EXT = struct.Struct("=QQQQQIIII")


def extents(path, batch=1024):
    out = []
    fd = os.open(path, os.O_RDONLY)
    try:
        start = 0
        while True:
            buf = bytearray(FIEMAP_HDR.size + FIEMAP_EXT.size * batch)
            FIEMAP_HDR.pack_into(buf, 0, start, 2 ** 64 - 1 - start, 1, 0, batch, 0)
            fcntl.ioctl(fd, FIEMAP, buf)
            mapped = FIEMAP_HDR.unpack_from(buf, 0)[3]
            if mapped == 0:
                break
            last = False
            for i in range(mapped):
                lo, ph, ln, _, _, flags, _, _, _ = FIEMAP_EXT.unpack_from(buf, FIEMAP_HDR.size + i * FIEMAP_EXT.size)
                out.append((lo, ph, ln))
                last = last or bool(flags & 1)
            if last:
                break
            start = out[-1][0] + out[-1][2]
    finally:
        os.close(fd)
    return out


def changed_ranges(cur, base):
    # Byte ranges of cur that no longer map to the same physical blocks as base at the same offset, holes on either side included.
    # The guest cannot hide a write from this, because btrfs keeps the original extents shared until they are overwritten.
    # Compressed extents can split into references that compare unequal, which only overcounts.
    # Also returns the bytes written and the bytes trimmed away, which the guest does to free space.
    a = sorted((lo, lo + ln, ph - lo) for lo, ph, ln in extents(cur))
    b = sorted((lo, lo + ln, ph - lo) for lo, ph, ln in extents(base))
    out = []
    written = trimmed = 0
    i = j = 0
    points = sorted({p for e in a + b for p in e[:2]})
    for lo, hi in zip(points, points[1:]):
        while i < len(a) and a[i][1] <= lo:
            i += 1
        while j < len(b) and b[j][1] <= lo:
            j += 1
        here = a[i][2] if i < len(a) and a[i][0] <= lo else None
        there = b[j][2] if j < len(b) and b[j][0] <= lo else None
        if here != there:
            if here is None:
                trimmed += hi - lo
            else:
                written += hi - lo
            if out and out[-1][1] == lo:
                out[-1][1] = hi
            else:
                out.append([lo, hi])
    return out, written, trimmed


def layer_ranges(live, target):
    # Guest disk ranges held by a layer above target: everything written since that snapshot, discards included.
    chain = [e["filename"] for e in json.loads(run(["qemu-img", "info", "--backing-chain", "--output=json", "-U", live]))]
    depth = chain.index(target) if target in chain else len(chain)
    out = []
    for e in json.loads(run(["qemu-img", "map", "--output=json", "-U", live])):
        if e["depth"] < depth and e.get("present", True):
            if out and out[-1][1] == e["start"]:
                out[-1][1] = e["start"] + e["length"]
            else:
                out.append([e["start"], e["start"] + e["length"]])
    return out


def image_info(path):
    return json.loads(run(["qemu-img", "info", "--output=json", "-U", path]))


def system_disk(disk):
    definition = disk.spec.get("definition")
    if not definition:
        die("the config has no domain definition for %s" % disk.dom)
    for d in ET.parse(definition).getroot().iter("disk"):
        src, tgt = d.find("source"), d.find("target")
        if d.get("device", "disk") != "disk" or src is None or tgt is None:
            continue
        if src.get("file") and src.get("file") != disk.image:
            return tgt.get("dev"), src.get("file")
    die("no system disk in %s" % definition)


def domain_disks(dom):
    disks = []
    for line in run(["virsh", "domblklist", dom, "--details", "--inactive"]).splitlines()[2:]:
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0] == "file" and parts[1] == "disk":
            disks.append((parts[2], parts[3].strip()))
    return disks


def live_source(dom, tdev):
    for target, source in domain_disks(dom):
        if target == tdev:
            return source
    die("%s has no disk %s" % (dom, tdev))


def disk_size(disk):
    if disk.spec.get("size"):
        return parse_size(disk.spec["size"])
    tdev, base = system_disk(disk)
    # The live image is what the guest sees, so a resized snapshot layer counts. A domain not defined yet falls back to its definition.
    p = subprocess.run(["virsh", "domblklist", disk.dom, "--details", "--inactive"], capture_output=True, text=True)
    for line in p.stdout.splitlines()[2:] if p.returncode == 0 else []:
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[2] == tdev and os.path.exists(parts[3].strip()):
            base = parts[3].strip()
    return image_info(base)["virtual-size"] if os.path.exists(base) else None


def to_bytes(text, current):
    m = re.fullmatch(r"([+-]?)(\d+)([KMGT]?)", text.strip().upper())
    if not m:
        die("invalid size: %s (use for example 600G, +100G or -50G)" % text)
    n = int(m.group(2)) * 1024 ** "_KMGT".index(m.group(3) or "_")
    size = {"+": current + n, "-": current - n}.get(m.group(1), n)
    # Whole sectors, so a size can match a real drive's exact capacity.
    return size >> 9 << 9


def revert_base(dom, tdev):
    p = subprocess.run(["virsh", "snapshot-current", "--name", dom], capture_output=True, text=True)
    name = p.stdout.strip() if p.returncode == 0 else ""
    if not name:
        die("%s has no current snapshot to revert to" % dom)
    for d in ET.fromstring(run(["virsh", "snapshot-dumpxml", dom, name])).iter("disk"):
        tgt, src = d.find("target"), d.find("source")
        if tgt is not None and src is not None and tgt.get("dev") == tdev and src.get("file"):
            return name, src.get("file")
    die("snapshot %s records no source for %s" % (name, tdev))


def backup(dom, images):
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bdir = os.path.join(os.path.dirname(images[0]), ".backup", "%s-%s" % (dom, stamp))
    os.makedirs(bdir, mode=0o700)
    seen = set()
    for image in images:
        for entry in json.loads(run(["qemu-img", "info", "--backing-chain", "--output=json", "-U", image])):
            if entry["filename"] not in seen:
                seen.add(entry["filename"])
                reflink(entry["filename"], os.path.join(bdir, os.path.basename(entry["filename"])))
    xml = run(["virsh", "dumpxml", dom, "--inactive", "--security-info"])
    with open(os.path.join(bdir, "domain.xml"), "w") as f:
        f.write(xml)
    for name in run(["virsh", "snapshot-list", dom, "--name"]).split():
        with open(os.path.join(bdir, "snapshot-%s.xml" % name), "w") as f:
            f.write(run(["virsh", "snapshot-dumpxml", dom, name, "--security-info"]))
    root = ET.fromstring(xml)
    nvram = root.findtext("./os/nvram")
    if nvram and os.path.exists(nvram.strip()):
        shutil.copy2(nvram.strip(), bdir)
    dom_uuid = (root.findtext("uuid") or "").strip()
    if dom_uuid and os.path.isdir("/var/lib/libvirt/swtpm/" + dom_uuid):
        shutil.copytree("/var/lib/libvirt/swtpm/" + dom_uuid, os.path.join(bdir, "swtpm"), symlinks=True)
    return bdir


class Exports:
    def __init__(self, cfg, dom):
        self.cfg = cfg
        self.uid = self.gid = None
        parent = None
        if os.geteuid() == 0:
            pw = pwd.getpwnam(cfg["user"])
            self.uid, self.gid = pw.pw_uid, pw.pw_gid
            parent = "/run/nixvirt-data"
            os.makedirs(parent, mode=0o755, exist_ok=True)
        self.dir = tempfile.mkdtemp(prefix=dom + ".", dir=parent)
        os.chmod(self.dir, 0o711)
        self.tmp = os.path.join(self.dir, "tmp")
        os.mkdir(self.tmp, 0o700)
        if self.uid is not None:
            os.chown(self.tmp, self.uid, self.gid)
        self.pids = {}
        self.socks = {}

    def start(self, name, path, fmt, ro=True, discard=False):
        sock = os.path.join(self.dir, name + ".sock")
        pidfile = os.path.join(self.dir, name + ".pid")
        cmd = ["qemu-nbd", "--format=" + fmt, "--socket=" + sock, "--persistent", "--fork", "--pid-file=" + pidfile]
        if ro:
            cmd.append("--read-only")
        if discard:
            cmd.append("--discard=unmap")
        run(cmd + [path])
        with open(pidfile) as f:
            self.pids[name] = int(f.read().strip())
        if self.uid is not None:
            os.chown(sock, self.uid, self.gid)
        self.socks[name] = sock

    def drive(self, name, as_name=None, ro=True, discard=False, system=False):
        return {"name": as_name or name, "sock": self.socks[name], "ro": ro, "discard": discard, "system": system}

    def stop(self, name):
        pid = self.pids.pop(name, None)
        self.socks.pop(name, None)
        if pid is None:
            return
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        for _ in range(200):
            if not os.path.exists("/proc/%d" % pid):
                return
            time.sleep(0.05)
        os.kill(pid, signal.SIGKILL)

    def close(self):
        for name in list(self.pids):
            self.stop(name)
        shutil.rmtree(self.dir, ignore_errors=True)

    def call(self, req, late=None, show=None):
        # late: a function whose fields reach the worker after it started, so slow host work overlaps with it.
        # show: gets each progress step the worker reports.
        env = [
            "env", "-i",
            "PATH=" + os.environ.get("PATH", ""),
            "HOME=" + self.tmp,
            "TMPDIR=" + self.tmp,
            "LIBGUESTFS_CACHEDIR=" + self.tmp,
            "LIBGUESTFS_PATH=" + self.cfg["appliance"],
            "LIBGUESTFS_BACKEND=direct",
            sys.executable, SELF, CONFIG_PATH, "_worker",
        ]
        cmd = env
        if self.uid is not None:
            # The appliance kernel parses guest-controlled filesystems, so a successful exploit must land in an unprivileged qemu with no network.
            cmd = [
                "unshare", "--net", "--",
                "setpriv", "--reuid=%d" % self.uid, "--regid=%d" % self.gid, "--init-groups",
                "--no-new-privs", "--inh-caps=-all", "--bounding-set=-all", "--",
            ] + env
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        errors = []

        def read_errors():
            for line in p.stderr:
                if line.startswith(b"\0progress "):
                    if show:
                        show(*json.loads(line[len(b"\0progress "):]))
                else:
                    errors.append(line)

        reader = threading.Thread(target=read_errors, daemon=True)
        reader.start()
        try:
            p.stdin.write(json.dumps(dict(req, late=late is not None)).encode() + b"\n")
            p.stdin.flush()
            if late is not None:
                p.stdin.write(json.dumps(late()).encode() + b"\n")
            p.stdin.close()
        except BrokenPipeError:
            pass
        out = p.stdout.read()
        p.wait()
        reader.join()
        if p.returncode != 0:
            err = safe(b"".join(errors).decode("utf-8", "replace").strip())
            die("guest disk access failed:\n" + err[-4000:])
        return json.loads(out)


class Rules:
    def __init__(self, r):
        self.sources = [s.strip("/").lower() for s in r.get("source_paths", [])]
        highlight = r.get("highlight", {})
        self.code = [p.lower() for p in highlight.get(RUNS_CODE, [])]
        self.sections = [(t, [p.lower() for p in pats]) for t, pats in highlight.items() if t != RUNS_CODE]

    def titles(self):
        return [RUNS_CODE] + [t for t, _ in self.sections]

    @staticmethod
    def under(path, top):
        return path == top or path.startswith(top + "/")

    def runs_code(self, low):
        parts = low.split("/")
        name = parts[-1]
        ext = name.rsplit(".", 1)[-1] if "." in name else ""
        if ext in BINARY_EXT or name in AUTORUN_NAMES or ".vscode" in parts:
            return True
        if ".git" in parts:
            i = parts.index(".git")
            if parts[i + 1:i + 2] == ["hooks"] or parts[i + 1:] == ["config"]:
                return True
        if any(fnmatch.fnmatchcase(low, p) for p in self.code):
            return True
        return ext in SCRIPT_EXT and not any(self.under(low, s) for s in self.sources)

    def flag(self, path, mode=None):
        low = path.lower()
        if self.runs_code(low) or (mode is not None and mode & 0o111):
            return RUNS_CODE
        for title, pats in self.sections:
            if any(fnmatch.fnmatchcase(low, p) for p in pats):
                return title
        return None


def progress(step, done=None, total=None):
    # Exports.call shows these on the terminal while the worker runs.
    sys.stderr.write("\0progress %s\n" % json.dumps([step, done, total]))
    sys.stderr.flush()


def late_fields(req):
    # Fields the host sends once the worker is running, like the written ranges it works out meanwhile.
    if req.pop("late", False):
        req.update(json.loads(sys.stdin.readline()))


def worker():
    import guestfs

    req = json.loads(sys.stdin.readline())
    g = guestfs.GuestFS(python_return_dict=True)
    names = []
    for d in req["drives"]:
        g.add_drive_opts("", format="raw", readonly=d["ro"], protocol="nbd", server=["unix:" + d["sock"]],
                         discard="enable" if d.get("discard") else None)
        names.append(d["name"])
    ops = {"scan": scan, "apply": apply, "carry": carry, "link": link, "unlink": unlink, "trim": trim,
           "carry_scan": carry_scan, "carry_into": carry_into, "resize_plan": resize_plan, "resize_apply": resize_apply}
    g.set_smp(max(1, min(4, os.cpu_count() or 1)))
    try:
        progress("starting the appliance")
        g.launch()
        progress("opening the disks")
        dev = dict(zip(names, g.list_devices()))
        fs = g.list_filesystems()
        mp = {n: "/" + n for n in names}
        for n in names:
            g.mkmountpoint(mp[n])
        # Inspection mounts filesystems itself, so it runs before an op mounts anything, and only when no Windows was found.
        req["systems"], roots = {}, None
        for d in req["drives"]:
            if d.get("system"):
                found = find_windows(g, fs, dev[d["name"]], mp[d["name"]], req.get("probes", []))
                if found is None:
                    roots = g.inspect_os() if roots is None else roots
                    found = find_linux(g, fs, dev[d["name"]], roots)
                req["systems"][d["name"]] = found
        out = ops[req["op"]](g, req, dev, fs, mp)
        g.umount_all()
        g.shutdown()
    except RuntimeError as e:
        sys.exit(str(e))
    finally:
        g.close()
    # Read what the host still sends, or it could block writing into a full pipe while this blocks writing the reply.
    late_fields(req)
    json.dump(out, sys.stdout)


def fs_parts(g, fs, dev):
    parts = [p for p, t in fs.items() if t not in ("unknown", "swap") and (p == dev or re.fullmatch(re.escape(dev) + r"\d+", p))]
    return sorted(parts, key=lambda p: 0 if p == dev else g.part_to_partnum(p))


def mount_data(g, fs, dev, mountpoint, rw):
    parts = fs_parts(g, fs, dev)
    if not parts:
        return None
    (g.mount if rw else g.mount_ro)(parts[0], mountpoint)
    return parts[0]


def device_of(mountable):
    # btrfsvol:/dev/sda2/subvolume names a subvolume of /dev/sda2.
    return "/".join(mountable[len("btrfsvol:"):].split("/")[:3]) if mountable.startswith("btrfsvol:") else mountable


def on_drive(g, mountable, dev):
    device = device_of(mountable)
    if re.fullmatch(re.escape(dev) + r"\d*", device):
        return True
    try:
        vg = g.lvm_canonical_lv_name(device).split("/")[2]
    except RuntimeError:
        return False
    uuids = {u.replace("-", "") for u in g.vgpvuuids(vg)}
    return any(p["pv_uuid"].replace("-", "") in uuids and re.fullmatch(re.escape(dev) + r"\d*", p["pv_name"]) for p in g.pvs_full())


def find_windows(g, fs, dev, mountpoint, probes):
    for p in fs_parts(g, fs, dev):
        if fs[p] != "ntfs":
            continue
        try:
            g.mount_ro(p, mountpoint)
        except RuntimeError:
            continue
        found = any(g.is_dir(mountpoint + "/" + x, followsymlinks=False) for x in ["Windows"] + probes)
        g.umount(mountpoint)
        if found:
            return {"os": "windows", "mounts": [["", p]]}
    return None


def find_linux(g, fs, dev, roots):
    # Any guest but Windows is assembled from its fstab, which libguestfs inspection reads inside the appliance.
    for root in roots:
        if not on_drive(g, root, dev):
            continue
        pairs = []
        for k, v in g.inspect_get_mountpoints(root).items():
            if not on_drive(g, v, dev):
                # Copies of one disk share filesystem UUIDs, so an fstab entry can resolve to the copy on another drive.
                m = re.fullmatch(r"(btrfsvol:)?/dev/[sv]d[a-z]+(\d+)(/.*)?", v)
                mine = m and (m.group(1) or "") + dev + m.group(2) + (m.group(3) or "")
                if not mine or device_of(mine) not in fs or g.vfs_uuid(device_of(mine)) != g.vfs_uuid(device_of(v)):
                    continue
                v = mine
            pairs.append([k.strip("/"), v])
        return {"os": "linux", "mounts": sorted(pairs, key=lambda kv: (kv[0] != "", kv[0].count("/")))}
    return None


def mount_tree(g, system, mountpoint, rw=False, swap=None, fs=None):
    # swap mounts the same layout from a copy of the disk, as (original drive, copy). With fs given, what the copy lacks is
    # skipped, and the result says whether its root was there.
    rooted = False
    for rel, m in system["mounts"]:
        if swap:
            if not device_of(m).startswith(swap[0]):
                raise SystemExit("%s is on LVM, which cannot be opened next to a copy of itself" % m)
            m = m.replace(swap[0], swap[1], 1)
            if fs is not None and device_of(m) not in fs:
                continue
        target = mountpoint + ("/" + rel if rel else "")
        rooted = rooted or not rel
        if rw:
            g.mount(m, target)
            continue
        try:
            g.mount_ro(m, target)
        except RuntimeError:
            if g.vfs_type(m) not in ("ext3", "ext4"):
                raise
            # A journal left by a crash cannot be replayed on a read-only drive, so it is read as last written.
            g.mount_options("ro,noload", m, target)
    return rooted


def join(a, b):
    return a + "/" + b if a else b


def checked(path):
    parts = path.split("/")
    if not path or any(p in ("", ".", "..") for p in parts):
        raise SystemExit("refusing unsafe path: %r" % path)
    return path


FIND_FORMAT = r"%y\0%s\0%T@\0%C@\0%i\0%m\0%l\0%p\0"
FIND_TYPES = {"f": "r", "p": "f"}


def stamp(text):
    # find prints a time as seconds with a fraction, and this splits it the way stat gives sec and nsec.
    whole, _, frac = text.partition(".")
    sec, nsec = int(whole), int((frac + "000000000")[:9])
    if whole.startswith("-") and nsec:
        sec, nsec = sec - 1, 1_000_000_000 - nsec
    return sec, nsec


def start_walks(g, specs, first=0):
    # One find per tree inside the appliance, all running at once: a call per folder costs a round trip each, nine times slower.
    # They run detached, so the worker can read other disks meanwhile, and each leaves its exit status last.
    # specs: (top, prune patterns relative to top, only this child of top or None).
    jobs = []
    for k, (top, prune, only) in enumerate(specs, first):
        cond = " -o ".join("-ipath %s" % shlex.quote("./" + pat) for pat in prune)
        out = "/sysroot/.nv-walk%d" % k
        jobs.append("rm -f %s %s.err %s.tmp %s.rc; { (cd %s && find %s %s-printf %s) > %s 2> %s.err; echo $? > %s.tmp && mv %s.tmp %s.rc; } "
                    "</dev/null >/dev/null 2>&1 &" % (
                        out, out, out, out, shlex.quote("/sysroot" + top), shlex.quote("./" + only if only else "."),
                        "\\( %s \\) -prune -o " % cond if cond else "", shlex.quote(FIND_FORMAT), out, out, out, out, out))
    appliance_sh(g, " ".join(jobs) + " true")


def finish_walks(g, specs, limit=5_000_000, first=0):
    appliance_sh(g, "for k in %s; do while [ ! -e /sysroot/.nv-walk$k.rc ]; do sleep 0.05; done; done"
                 % " ".join(str(k) for k in range(first, first + len(specs))))
    tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "walk")
    trees = []
    for k, (top, _, _) in enumerate(specs, first):
        if g.read_file("/.nv-walk%d.rc" % k).strip() != b"0":
            raise SystemExit("listing %s failed: %s" % (top, g.read_file("/.nv-walk%d.err" % k).decode("utf-8", "replace")[-2000:]))
        g.download("/.nv-walk%d" % k, tmp)
        with open(tmp, "rb") as f:
            fields = f.read().split(b"\0")
        os.unlink(tmp)
        # ntfs-3g resolves junction targets to absolute paths under the mountpoint, which differs between the trees being compared.
        mount_root = "/sysroot/" + top.strip("/").split("/")[0]
        tree = {}
        for i in range(0, len(fields) - 1, 8):
            kind, size, mtime, ctime, ino, mode, link, path = (x.decode("utf-8", "surrogateescape") for x in fields[i:i + 8])
            rel = path[2:]
            if not rel:
                continue
            t = FIND_TYPES.get(kind, kind)
            target = (link[len(mount_root):] if link.startswith(mount_root + "/") else link) if t == "l" else None
            tree[rel] = (t, int(size) if t == "r" else 0, *stamp(mtime), target, int(ino), int(mode, 8), *stamp(ctime))
        if len(tree) > limit:
            raise SystemExit("more than %d entries under %s" % (limit, top))
        trees.append(tree)
    return trees


def walks(g, specs, limit=5_000_000, first=0):
    start_walks(g, specs, first)
    return finish_walks(g, specs, limit, first)


def walk(g, top, prune=(), only=None):
    return walks(g, [(top, prune, only)])[0]


def glob_escape(path):
    return re.sub(r"([*?[])", r"[\1]", path)


def unescape_sum_name(name):
    out = []
    i = 0
    while i < len(name):
        c = name[i]
        if c == "\\" and i + 1 < len(name):
            out.append({"n": "\n", "r": "\r", "\\": "\\"}.get(name[i + 1], name[i + 1]))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def hashes(g, top, rel_dirs, tmpdir):
    found = {}
    for rd in rel_dirs:
        d = top + "/" + rd if rd else top
        if g.is_file(d, followsymlinks=False):
            found[rd] = g.checksum("sha256", d)
            continue
        if not g.is_dir(d, followsymlinks=False):
            continue
        sums = os.path.join(tmpdir, "sums")
        g.checksums_out("sha256", d, sums)
        with open(sums, "rb") as f:
            data = f.read()
        os.unlink(sums)
        for line in data.split(b"\n"):
            if not line:
                continue
            escaped = line.startswith(b"\\")
            if escaped:
                line = line[1:]
            digest, _, name = line.partition(b"  ")
            name = name.decode("utf-8", "surrogateescape")
            if escaped:
                name = unescape_sum_name(name)
            if name.startswith("./"):
                name = name[2:]
            found[join(rd, name)] = digest.decode()
    return found


def round_up(n):
    return (n + 4095) // 4096 * 4096


MFT_REF = (1 << 48) - 1
U16 = struct.Struct("<H").unpack_from
U32 = struct.Struct("<I").unpack_from
U64 = struct.Struct("<Q").unpack_from
ATTR_HEAD = struct.Struct("<II").unpack_from
NTFS_EPOCH = 116444736000000000


class Unreadable(Exception):
    pass


class Ranges:
    def __init__(self, pairs):
        self.starts = [a for a, _ in pairs]
        self.ends = [b for _, b in pairs]

    def hit(self, a, b):
        i = bisect.bisect_right(self.starts, a) - 1
        if i >= 0 and self.ends[i] > a:
            return True
        return i + 1 < len(self.starts) and self.starts[i + 1] < b

    def overlaps(self, a, b):
        i = max(bisect.bisect_right(self.starts, a) - 1, 0)
        while i < len(self.starts) and self.starts[i] < b:
            if self.ends[i] > a:
                yield max(a, self.starts[i]), min(b, self.ends[i])
            i += 1


class Ntfs:
    # Reads the on-disk structures a write has to touch to change a file: its MFT records and the clusters of each of its streams.
    def __init__(self, g, part):
        self.g, self.part = g, part
        bs = g.pread_device(part, 512, 0)
        if bs[3:11] != b"NTFS    ":
            raise ValueError("%s is not NTFS" % part)
        spc = bs[0x0D]
        self.cs = U16(bs, 0x0B)[0] * (1 << (256 - spc) if spc > 0x80 else spc)
        per = struct.unpack_from("<b", bs, 0x40)[0]
        self.rs = self.cs * per if per > 0 else 1 << -per
        self.set_mft([(0, U64(bs, 0x30)[0], max(1, self.rs // self.cs))])
        rec = self.parse(self.record(0))
        ext = self.extensions(rec, 0) if rec else None
        if ext is None:
            raise ValueError("%s has an unreadable $MFT record" % part)
        runs = self.data_runs(rec)
        # A fragmented $MFT keeps the rest of its runlist in extension records, which lie in the part already known.
        for _, raw in self.records(ext):
            runs += self.data_runs(self.parse(raw) or {"attrs": []})
        self.set_mft(sorted(runs))
        size = next((a["size"] for a in rec["attrs"] if a["type"] == 0x80 and not a["name"] and a["runs"] and a["runs"][0][0] == 0), 0)
        self.count = size // self.rs

    def set_mft(self, runs):
        self.mft = runs
        self.mft_vcns = [r[0] for r in runs]

    @staticmethod
    def data_runs(rec):
        return [r for a in rec["attrs"] if a["type"] == 0x80 and not a["name"] for r in a["runs"] or [] if r[1] is not None]

    def locate(self, n):
        pos = n * self.rs
        i = bisect.bisect_right(self.mft_vcns, pos // self.cs) - 1
        if i < 0:
            return None
        start, lcn, length = self.mft[i]
        if (pos + self.rs - 1) // self.cs >= start + length:
            return None
        return lcn * self.cs + pos - start * self.cs

    def records(self, nums, chunk=2 << 20):
        # Neighbouring records are read in one request, and only one chunk is held at a time.
        offs = sorted((off, n) for n in set(nums) if (off := self.locate(n)) is not None)
        i = 0
        while i < len(offs):
            j = i
            while j + 1 < len(offs) and offs[j + 1][0] + self.rs - offs[i][0] <= chunk:
                j += 1
            start = offs[i][0]
            data = self.g.pread_device(self.part, offs[j][0] + self.rs - start, start)
            for off, n in offs[i:j + 1]:
                yield n, data[off - start:off - start + self.rs]
            i = j + 1

    def record(self, n):
        return next((raw for _, raw in self.records([n])), None)

    @staticmethod
    def fixup(b):
        # Each 512-byte block ends in the update sequence number and its real bytes sit in the array, so a mismatch is a torn write.
        usa, count = U16(b, 4)[0], U16(b, 6)[0]
        if count < 1 or usa + 2 * count > len(b):
            return False
        usn = b[usa:usa + 2]
        for k in range(1, count):
            end = k * 512
            if end > len(b) or b[end - 2:end] != usn:
                return False
            b[end - 2:end] = b[usa + 2 * k:usa + 2 * k + 2]
        return True

    @staticmethod
    def runlist(b, i, end, vcn):
        runs, lcn = [], 0
        while i < end and b[i]:
            ln, lo = b[i] & 0x0F, b[i] >> 4
            if not ln or i + 1 + ln + lo > end:
                break
            length = int.from_bytes(b[i + 1:i + 1 + ln], "little")
            if lo:
                lcn += int.from_bytes(b[i + 1 + ln:i + 1 + ln + lo], "little", signed=True)
                runs.append((vcn, lcn, length))
            else:
                runs.append((vcn, None, length))
            vcn += length
            i += 1 + ln + lo
        return runs

    def parse(self, raw):
        if not raw or raw[:4] != b"FILE":
            return None
        b = bytearray(raw)
        if not self.fixup(b):
            return None
        attrs = []
        off = U16(b, 0x14)[0]
        while off + 24 <= len(b):
            kind, size = U32(b, off)[0], U32(b, off + 4)[0]
            if kind == 0xFFFFFFFF or size < 24 or off + size > len(b):
                break
            nlen, noff = b[off + 9], U16(b, off + 10)[0]
            name = bytes(b[off + noff:off + noff + 2 * nlen])
            if b[off + 8]:
                runs = self.runlist(b, off + U16(b, off + 0x20)[0], off + size, U64(b, off + 0x10)[0])
                attrs.append({"type": kind, "name": name, "runs": runs, "value": None, "size": U64(b, off + 0x30)[0],
                              "init": U64(b, off + 0x38)[0]})
            else:
                vlen, voff = U32(b, off + 0x10)[0], U16(b, off + 0x14)[0]
                attrs.append({"type": kind, "name": name, "runs": None, "value": bytes(b[off + voff:off + voff + vlen]), "size": vlen,
                              "init": -1})
            off += size
        return {"flags": U16(b, 0x16)[0], "attrs": attrs}

    def extensions(self, rec, n):
        # Record numbers holding the rest of a file's attributes, or None when its attribute list cannot be read.
        found = set()
        for a in rec["attrs"]:
            if a["type"] != 0x20:
                continue
            data = a["value"]
            if data is None:
                runs = [r for r in a["runs"] if r[1] is not None]
                if a["size"] > 1 << 20 or not runs:
                    return None
                data = self.g.pread_device(self.part, min(a["size"], runs[0][2] * self.cs), runs[0][1] * self.cs)
                if len(data) < a["size"]:
                    return None
            found |= list_refs(data, n)
        return found

    def every_record(self, chunk=2 << 20):
        # Every record slot in table order through large reads, one pass instead of a lookup per file.
        # A record split across two runs cannot be read this way, which only happens with clusters smaller than a record.
        done = 0
        for vcn, lcn, length in self.mft:
            lo, hi = vcn * self.cs, min((vcn + length) * self.cs, self.count * self.rs)
            n = -(-lo // self.rs)
            while (n + 1) * self.rs <= hi:
                k = min((hi - n * self.rs) // self.rs, max(1, chunk // self.rs))
                at = lcn * self.cs + n * self.rs - lo
                data = self.g.pread_device(self.part, k * self.rs, at)
                if len(data) < k * self.rs:
                    raise Unreadable("the MFT is shorter than its runlist")
                for j in range(k):
                    yield n + j, at + j * self.rs, data[j * self.rs:(j + 1) * self.rs]
                n += k
                done += k
        if done != self.count:
            raise Unreadable("the MFT has records split across its runs")

    def stream(self, runs, size, n):
        # A small non-resident attribute read whole: an attribute list or reparse data.
        data = b""
        for _, lcn, ln in runs:
            if len(data) >= size:
                break
            if lcn is None or size > 1 << 20:
                raise Unreadable("record %d has an attribute list or reparse data that cannot be read" % n)
            data += self.g.pread_device(self.part, min(ln * self.cs, size - len(data)), lcn * self.cs)
        if len(data) < size:
            raise Unreadable("record %d has an attribute list or reparse data that cannot be read" % n)
        return data

    def summary(self, n, raw, off):
        # What a listing needs from one record, or None for a free slot: (base record, sequence, flags, mtime, ctime,
        # attributes, names, size, reparse data, attribute list, offset, clusters, outside). clusters are those of every
        # stream, for the block check's second tier, and only kept for files since it only checks files. outside are those
        # of an attribute list or reparse data, which the listing read from beyond the record.
        if raw[:4] != b"FILE":
            return None
        flags = U16(raw, 0x16)[0]
        if not flags & 1:
            return None
        b = bytearray(raw)
        if not self.fixup(b):
            raise Unreadable("MFT record %d is torn" % n)
        keep = not flags & 2
        clusters, outside = [], []
        mtime = ctime = attrib = 0
        names, size, reparse, ext = [], None, None, None
        i, end = U16(b, 0x14)[0], len(b)
        while i + 24 <= end:
            kind, length = ATTR_HEAD(b, i)
            if kind == 0xFFFFFFFF:
                break
            if length < 24 or i + length > end:
                raise Unreadable("MFT record %d has a malformed attribute" % n)
            unnamed = not b[i + 9]
            if b[i + 8]:
                vcn = U64(b, i + 0x10)[0]
                other = kind in (0x20, 0xC0)
                if keep or other:
                    runs = self.runlist(b, i + U16(b, i + 0x20)[0], i + length, vcn)
                    if keep:
                        clusters += [(lcn, ln) for _, lcn, ln in runs if lcn is not None]
                if kind == 0x80 and unnamed and vcn == 0:
                    size = U64(b, i + 0x30)[0]
                elif other:
                    outside += [(lcn, ln) for _, lcn, ln in runs if lcn is not None]
                    data = self.stream(runs, U64(b, i + 0x30)[0], n)
                    if kind == 0x20:
                        ext = list_refs(data, n)
                    else:
                        reparse = data
            else:
                vlen, voff = U32(b, i + 0x10)[0], U16(b, i + 0x14)[0]
                v = i + voff
                if v + vlen > i + length:
                    raise Unreadable("MFT record %d has a malformed attribute" % n)
                if kind == 0x10 and vlen >= 0x24:
                    mtime, ctime, attrib = U64(b, v + 0x08)[0], U64(b, v + 0x10)[0], U32(b, v + 0x20)[0]
                elif kind == 0x30 and vlen >= 0x42 and b[v + 0x41] != 2:
                    # DOS 8.3 aliases are left out, as ntfs-3g leaves them out of a directory listing.
                    names.append((U64(b, v)[0], b[v + 0x42:v + 0x42 + 2 * b[v + 0x40]].decode("utf-16-le", "replace")))
                elif kind == 0x80 and unnamed:
                    size = vlen
                elif kind == 0xC0:
                    reparse = bytes(b[v:v + vlen])
                elif kind == 0x20:
                    ext = list_refs(b[v:v + vlen], n)
            i += length
        return (U64(b, 0x20)[0] & MFT_REF, U16(b, 0x10)[0], flags, mtime, ctime, attrib, names, size, reparse, ext, off,
                tuple(clusters), tuple(outside))

    def touched(self, ranges, n, rec):
        off = self.locate(n)
        if off is None or rec is None or ranges.hit(off, off + self.rs):
            return True
        return any(lcn is not None and ranges.hit(lcn * self.cs, (lcn + ln) * self.cs)
                   for a in rec["attrs"] for _, lcn, ln in a["runs"] or [])

    def changed_files(self, ranges, wanted):
        # Tier one is the file's own MFT records, which any change made through NTFS rewrites, forged timestamps included.
        # Tier two is every cluster of every stream, named ones too, which catches writes that went around NTFS to the raw disk.
        hits, pending, seen = set(), {}, set()
        for n, raw in self.records(wanted):
            seen.add(n)
            rec = self.parse(raw)
            if self.touched(ranges, n, rec) or not rec["flags"] & 1:
                hits.add(n)
                continue
            ext = self.extensions(rec, n)
            if ext is None:
                hits.add(n)
            elif ext:
                pending[n] = ext
        hits |= set(wanted) - seen
        more = dict(self.records({e for ext in pending.values() for e in ext}))
        for n, ext in pending.items():
            if any(self.touched(ranges, e, self.parse(more.get(e))) for e in ext):
                hits.add(n)
        return hits

    def signatures(self, nums):
        # What each file's content is made of: every stream's sizes, clusters and inline bytes, and any reparse data.
        base = {n: self.parse(raw) for n, raw in self.records(nums)}
        ext = {n: self.extensions(rec, n) for n, rec in base.items() if rec and rec["flags"] & 1}
        more = {e: self.parse(raw) for e, raw in self.records({e for es in ext.values() if es for e in es})}
        out = {}
        for n, es in ext.items():
            recs = [base[n]] + [more.get(e) for e in es or ()]
            if es is None or None in recs:
                continue
            out[n] = sorted((a["type"], a["name"], a["size"], a["init"], a["value"] or b"",
                             tuple((v, -1 if lcn is None else lcn, ln) for v, lcn, ln in a["runs"] or ()))
                            for r in recs for a in r["attrs"] if a["type"] in (0x80, 0xC0))
        return out

    def journal_clean(self):
        # This driver never replays the NTFS journal, but Windows does at its next mount, which can change files a scan missed.
        rec = self.parse(self.record(2))
        runs = self.data_runs(rec) if rec else []
        if not runs:
            return False
        first = runs[0][1] * self.cs
        head = self.g.pread_device(self.part, 4096, first)
        page = U32(head, 0x10)[0] if head[:4] in (b"RSTR", b"CHKD") else 4096
        if page not in (4096, 8192, 16384, 32768, 65536):
            page = 4096
        newest = None
        for k in range(2):
            b = bytearray(self.g.pread_device(self.part, page, first + k * page))
            if b[:4] not in (b"RSTR", b"CHKD") or not self.fixup(b) or U16(b, 0x18)[0] + 16 > page:
                continue
            lsn, _, _, in_use, flags = struct.unpack_from("<qHHHH", b, U16(b, 0x18)[0])
            if newest is None or lsn > newest[0]:
                newest = (lsn, in_use, flags)
        return newest is None or newest[1] == 0xFFFF or bool(newest[2] & 0x0002)


def list_refs(data, n):
    refs, i = set(), 0
    while i + 0x18 <= len(data):
        ref = U64(data, i + 0x10)[0] & MFT_REF
        if ref != n:
            refs.add(ref)
        size = U16(data, i + 4)[0]
        if size < 0x18:
            break
        i += size
    return refs


def ntfs_time(t):
    # Split the way ntfs-3g fills st_mtim, so the values match what the mounted volume reports.
    t -= NTFS_EPOCH
    return t // 10_000_000, t % 10_000_000 * 100


def reparse_target(data):
    # The name Windows follows for a junction or symlink. Any other reparse point reads the way ntfs-3g shows one it cannot follow.
    tag = U32(data, 0)[0] if len(data) >= 8 else 0
    head = {0xA0000003: 8, 0xA000000C: 12}.get(tag)
    if head and len(data) >= 8 + head:
        sub, length = U16(data, 8)[0], U16(data, 10)[0]
        return data[8 + head + sub:8 + head + sub + length].decode("utf-16-le", "replace")
    return "unsupported reparse tag 0x%08x" % tag


def mft_tree(recs, limit=5_000_000):
    # The entries find lists on the mounted volume: metadata files and DOS aliases left out, every hard link listed.
    info, kids = {}, {}
    for n, (base, seq, flags, mtime, ctime, attrib, names, size, reparse, ext, *_) in recs.items():
        if base:
            continue
        for e in ext or ():
            x = recs.get(e)
            if x is None or x[0] != n:
                raise Unreadable("record %d lists an extension record that is not its own" % n)
            names = names + x[6]
            size = size if x[7] is None else x[7]
            reparse = reparse if x[8] is None else x[8]
        info[n] = (seq, flags, mtime, ctime, attrib, size, reparse)
        if n >= 16:
            for ref, name in names:
                kids.setdefault(ref & MFT_REF, []).append((ref >> 48, name, n))
    if 5 not in info:
        raise Unreadable("the root folder record is missing")
    tree, stack, seen = {}, [(5, "")], {5}
    while stack:
        d, prefix = stack.pop()
        for seq, name, n in kids.get(d, ()):
            # A child naming another sequence number of its folder's record belongs to an earlier, deleted folder.
            if seq != info[d][0] or name in (".", ".."):
                continue
            _, flags, mtime, ctime, attrib, size, reparse = info[n]
            path = prefix + "/" + name if prefix else name
            if reparse is not None or attrib & 0x400:
                entry = ("l", 0, *ntfs_time(mtime), reparse_target(reparse or b""), n, 0o777, *ntfs_time(ctime))
            elif flags & 2:
                entry = ("d", 0, *ntfs_time(mtime), None, n, 0o777, *ntfs_time(ctime))
                if n not in seen:
                    seen.add(n)
                    stack.append((n, path))
            else:
                entry = ("r", size or 0, *ntfs_time(mtime), None, n, 0o777, *ntfs_time(ctime))
            tree[path] = entry
        if len(tree) > limit:
            raise SystemExit("more than %d entries on the data disk" % limit)
    return tree


def hits_any(ranges, cs, clusters):
    return any(ranges.hit(lcn * cs, (lcn + ln) * cs) for lcn, ln in clusters)


def mft_touched(nt, recs, ranges):
    # Files whose own records, extension records or stream clusters lie in written blocks: the two tiers of changed_files.
    own = {n for n, r in recs.items() if ranges.hit(r[10], r[10] + nt.rs) or hits_any(ranges, nt.cs, r[11])}
    return {n for n, r in recs.items() if not r[0] and (n in own or any(e in own for e in r[9] or ()))}


def mft_records(nt, step):
    recs = {}
    for n, off, raw in nt.every_record():
        r = nt.summary(n, raw, off)
        if r is not None:
            recs[n] = r
        if not n % 8192:
            progress(step, n, nt.count)
    return recs


def mft_before(nt, bnt, recs, ranges):
    # The earlier table, taking over every record that sits at the same place in both and outside the written blocks, since
    # those bytes are shared. Only the records written since are read again, and the guest cannot hide a write from ranges.
    if bnt.mft == nt.mft:
        changed = set()
        for vcn, lcn, length in nt.mft:
            for lo, hi in ranges.overlaps(lcn * nt.cs, (lcn + length) * nt.cs):
                changed.update(range((lo - lcn * nt.cs + vcn * nt.cs) // nt.rs, (hi - 1 - lcn * nt.cs + vcn * nt.cs) // nt.rs + 1))
    else:
        changed = {n for n in range(max(nt.count, bnt.count))
                   if (off := nt.locate(n)) is None or off != bnt.locate(n) or ranges.hit(off, off + nt.rs)}
    changed |= {n for n, r in recs.items() if hits_any(ranges, nt.cs, r[12])}
    changed |= set(range(nt.count, bnt.count))
    wanted = [n for n in changed if n < bnt.count]
    if any(bnt.locate(n) is None for n in wanted):
        raise Unreadable("the earlier MFT has records split across its runs")
    progress("reading what changed since rev0", 0, len(wanted))
    out = {n: r for n, r in recs.items() if n not in changed and n < bnt.count}
    for n, raw in bnt.records(wanted):
        r = bnt.summary(n, raw, None)
        if r is not None:
            out[n] = r
    return out


def partition_ranges(g, dev, part, ranges):
    start = part_offset(g, dev, part)
    end = start + g.blockdev_getsize64(part)
    return Ranges([(max(a, start) - start, min(b, end) - start) for a, b in ranges if b > start and a < end])


def mft_now(g, part):
    # One pass over the data disk's table instead of a filesystem lookup per file through ntfs-3g. It needs no written
    # ranges yet, so it runs while the host still works them out.
    nt = Ntfs(g, part)
    return nt, mft_records(nt, "reading the data disk table")


def mft_trees(g, nt, recs, ranges, dev, part, bdev=None, bpart=None):
    local = partition_ranges(g, dev, part, ranges) if ranges is not None else None
    base = None
    if bpart is not None:
        bnt = Ntfs(g, bpart)
        # Byte offsets only line up when the partition starts at the same place in both images.
        same = local is not None and part_offset(g, bdev, bpart) == part_offset(g, dev, part)
        base = mft_tree(mft_before(nt, bnt, recs, local) if same else mft_records(bnt, "reading the rev0 table"))
    progress("building the file lists")
    return mft_tree(recs), base or {}, mft_touched(nt, recs, local) if local is not None else set()


def part_offset(g, dev, part):
    if part == dev:
        return 0
    num = g.part_to_partnum(part)
    return next(p["part_start"] for p in g.part_list(dev) if p["part_num"] == num)


def same_bytes(g, part, bpart, sig, ranges, cs, budget=64 << 20):
    # With identical streams and clusters, the content differs only where written bytes differ, so only those are read.
    for *_, runs in sig:
        for _, lcn, ln in runs:
            if lcn < 0:
                continue
            for lo, hi in ranges.overlaps(lcn * cs, (lcn + ln) * cs):
                budget -= hi - lo
                if budget < 0:
                    return False
                for off in range(lo, hi, 1 << 20):
                    n = min(1 << 20, hi - off)
                    if g.pread_device(part, n, off) != g.pread_device(bpart, n, off):
                        return False
    return True


def compare_files(g, pairs):
    # Every pair goes in one call, four at a time, and cmp stops at the first differing byte.
    if not pairs:
        return set()
    tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "pairs")
    with open(tmp, "wb") as f:
        for now, before, _ in pairs:
            f.write(b"/sysroot%s\0/sysroot%s\0" % (now.encode("utf-8", "surrogateescape"), before.encode("utf-8", "surrogateescape")))
    g.upload(tmp, "/.nv-pairs")
    appliance_sh(g, "xargs -0 -n2 -P4 sh -c 'cmp -s -- \"$1\" \"$2\" || printf \"%s\\0\" \"$1\"' _ < /sysroot/.nv-pairs > /sysroot/.nv-differ")
    g.download("/.nv-differ", tmp)
    with open(tmp, "rb") as f:
        differ = {x.decode("utf-8", "surrogateescape")[len("/sysroot"):] for x in f.read().split(b"\0") if x}
    os.unlink(tmp)
    return {key for now, _, key in pairs if now in differ}


def block_check(g, dev, part, ranges, files, bdev, bpart, listed=None):
    # files: (inode now, inode before, path now, path before, key) for every file whose size and date did not change.
    # listed: (Ntfs of part, files the MFT listing found in written blocks), which spares reading every record again.
    if g.vfs_type(part) != "ntfs":
        return None
    progress("checking written blocks")
    start = part_offset(g, dev, part)
    local = partition_ranges(g, dev, part, ranges)
    now = listed[0] if listed else Ntfs(g, part)
    wanted = {}
    for ino, ino_before, now_path, before_path, key in files:
        wanted.setdefault(ino & MFT_REF, []).append((ino_before & MFT_REF, now_path, before_path, key))
    if not (local.starts and wanted):
        hits = []
    elif listed:
        hits = sorted(n for n in wanted if n in listed[1])
    else:
        hits = sorted(now.changed_files(local, list(wanted)))
    suspects = [(n,) + f for n in hits for f in wanted[n]]
    full = [(now_path, before_path, key) for _, _, now_path, before_path, key in suspects]
    # Byte offsets only line up when the partition starts at the same place in both images.
    if suspects and part_offset(g, bdev, bpart) == start:
        before = Ntfs(g, bpart)
        mine, theirs = now.signatures(hits), before.signatures({nb for _, nb, *_ in suspects})
        full = [(now_path, before_path, key) for n, nb, now_path, before_path, key in suspects
                if n not in mine or mine[n] != theirs.get(nb) or not same_bytes(g, part, bpart, mine[n], local, now.cs)]
    return {"suspects": len(suspects), "checked": len(full), "differ": sorted(compare_files(g, full)),
            "clean": now.journal_clean(), "complete": True}


def compare(base, cur, hb, hc, rules, with_deleted=True, prefix="", posix=False):
    # posix: the filesystem keeps real permission bits, so an execute bit marks code and a mode change counts.
    items = []
    groups = {}

    def top_missing(path, other):
        parts = path.split("/")
        for k in range(1, len(parts)):
            a = "/".join(parts[:k])
            if a not in other:
                return a
        return path

    def aggregate(path, entry, status, tree, other):
        top = top_missing(path, other)
        it = groups.get(top)
        if it is None:
            it = groups[top] = {
                "path": top, "st": status, "type": tree[top][0], "size": 0, "alloc": 0,
                "files": 0, "flagged": {}, "flag": None, "reason": None,
            }
            items.append(it)
        flag = None
        if entry[0] == "r":
            it["files"] += 1
            it["size"] += entry[1]
            it["alloc"] += round_up(entry[1])
            flag = rules.flag(prefix + path, entry[6] if posix else None)
        elif entry[0] == "l":
            flag = RUNS_CODE
        if flag:
            it["flagged"][flag] = it["flagged"].get(flag, 0) + 1

    for p, c in cur.items():
        b = base.get(p)
        if b is None:
            aggregate(p, c, "N", cur, base)
            continue
        reason = None
        if b[0] != c[0]:
            reason = "type"
        elif c[0] == "r":
            if b[1] != c[1]:
                reason = "size"
            elif b[2:4] != c[2:4]:
                reason = "date"
            elif p in hb and p in hc and hb[p] != hc[p]:
                reason = "content"
            elif posix and (b[6] ^ c[6]) & 0o7777:
                reason = "mode"
        elif c[0] == "l" and b[4] != c[4]:
            reason = "link"
        if reason:
            flag = RUNS_CODE if reason in ("type", "link") else (rules.flag(prefix + p, c[6] if posix else None) if c[0] == "r" else None)
            items.append({
                "path": p, "st": "M", "type": c[0], "size": c[1], "alloc": round_up(c[1]),
                "old_size": b[1], "files": 1 if c[0] == "r" else 0, "flag": flag, "flagged": {},
                "reason": reason, "link": c[4], "old_link": b[4], "mode": c[6] & 0o7777, "old_mode": b[6] & 0o7777,
            })
    if with_deleted:
        for p, b in base.items():
            if p not in cur:
                aggregate(p, b, "D", base, cur)
    for it in groups.values():
        it["flag"] = next((t for t in rules.titles() if it["flagged"].get(t)), None)
    items.sort(key=lambda it: it["path"])
    return items


def read_text(g, path):
    data = g.read_file(path)
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", "replace")


def attach_diffs(g, items, cur_top, base_top, labels=("rev0", "now"), budget=4 << 20):
    for it in items:
        if budget <= 0:
            break
        ext = it["path"].rsplit(".", 1)[-1].lower() if "." in it["path"] else ""
        flagged = it["flag"] or it["reason"] == "content"
        if not flagged or it["type"] != "r" or it["st"] == "D" or it["size"] > 256 << 10 or ext in BINARY_EXT:
            continue
        new = read_text(g, cur_top + "/" + it["path"])
        old = "" if it["st"] == "N" else read_text(g, base_top + "/" + it["path"])
        if new is None or old is None:
            continue
        lines = list(difflib.unified_diff(
            old.splitlines(), new.splitlines(),
            fromfile=labels[0] + "/" + it["path"], tofile=labels[1] + "/" + it["path"], lineterm="",
        ))[:2000]
        it["diff"] = [ln if len(ln) <= 300 else ln[:300] + " ..." for ln in lines]
        budget -= sum(len(ln) for ln in it["diff"])


def unchanged_files(cur, base, hb, hc, now_top, before_top, prefix="", posix=False):
    # On a POSIX filesystem only those with a new change time, which the kernel sets and a guest program cannot put back.
    return [(c[5], base[p][5], now_top + "/" + p, before_top + "/" + p, prefix + p) for p, c in cur.items()
            if c[0] == "r" and (b := base.get(p)) and b[0] == "r" and b[1:4] == c[1:4] and not (p in hb and p in hc)
            and (not posix or (b[7:9] != c[7:9] and not (b[6] ^ c[6]) & 0o7777))]


def ctime_check(g, files):
    differ = sorted(compare_files(g, [(now, before, key) for _, _, now, before, key in files]))
    return {"suspects": len(files), "checked": len(files), "differ": differ, "clean": True, "complete": False}


def tampered_item(path, now, before, rules):
    return {"path": path, "st": "M", "type": "r", "size": now[1], "alloc": round_up(now[1]), "old_size": before[1], "files": 1,
            "flag": rules.flag(path), "flagged": {}, "reason": "content", "link": None, "old_link": None}


def scan(g, req, dev, fs, mp):
    rules = Rules(req["rules"])
    tmpdir = os.environ.get("TMPDIR", "/tmp")
    dpart = mount_data(g, fs, dev["dcur"], mp["dcur"], False)
    bpart = mount_data(g, fs, dev["dbase"], mp["dbase"], False) if "dbase" in dev else None
    have_cur, have_base = dpart is not None, bpart is not None
    root = req.get("c_root")
    pair = None
    for i in req.get("c_pairs", []):
        system = req["systems"]["cs%d" % i]
        if system is None:
            continue
        mount_tree(g, system, mp["cs%d" % i])
        if not g.is_dir(mp["cs%d" % i] + "/" + root, followsymlinks=False):
            continue
        rooted = mount_tree(g, system, mp["ct%d" % i], swap=(dev["cs%d" % i], dev["ct%d" % i]), fs=fs)
        pair = (i, system, rooted and g.is_dir(mp["ct%d" % i] + "/" + root, followsymlinks=False))
        break
    patterns = [p.lower() for p in req.get("c_exclude", [])]
    timing, listed, lister = {}, None, "find"
    clock = time.monotonic()
    # The system disk folders are listed inside the appliance while the worker reads the data disk's table.
    cspecs = []
    if pair:
        cspecs.append((mp["cs%d" % pair[0]] + "/" + root, patterns, None))
        if pair[2]:
            cspecs.append((mp["ct%d" % pair[0]] + "/" + root, patterns, None))
        start_walks(g, cspecs)
    cur, base = {}, {}
    if have_cur and fs[dpart] == "ntfs" and (not have_base or fs[bpart] == "ntfs"):
        try:
            nt, recs = mft_now(g, dpart)
            late_fields(req)
            cur, base, touched = mft_trees(g, nt, recs, req.get("ranges"), dev["dcur"], dpart, dev.get("dbase"), bpart)
            listed, lister = (nt, touched), "mft"
        except (Unreadable, ValueError) as e:
            lister = "find (%s)" % e
    late_fields(req)
    if listed is None and (have_cur or have_base):
        progress("listing the data disk via ntfs-3g")
        dspecs = ([(mp["dcur"], (), None)] if have_cur else []) + ([(mp["dbase"], (), None)] if have_base else [])
        trees = iter(walks(g, dspecs, first=len(cspecs)))
        cur = next(trees) if have_cur else {}
        base = next(trees) if have_base else {}
    session = target = {}
    if pair:
        progress("listing the system disk")
        trees = iter(finish_walks(g, cspecs))
        session, target = next(trees), next(trees) if pair[2] else {}
    timing["list"], clock = time.monotonic() - clock, time.monotonic()
    hash_dirs = [""] if req["hash_all"] else req["hash_paths"]
    hc = hashes(g, mp["dcur"], hash_dirs, tmpdir) if have_cur else {}
    hb = hashes(g, mp["dbase"], hash_dirs, tmpdir) if have_base else {}
    timing["hash"], clock = time.monotonic() - clock, time.monotonic()
    posix = have_cur and fs[dpart] in POSIX_FS
    items = compare(base, cur, hb, hc, rules, posix=posix)
    blocks = None
    if have_cur and have_base and req.get("ranges") is not None:
        files = unchanged_files(cur, base, hb, hc, mp["dcur"], mp["dbase"], posix=posix)
        blocks = ctime_check(g, files) if posix else block_check(g, dev["dcur"], dpart, req["ranges"], files, dev["dbase"], bpart, listed)
        if blocks:
            items += [tampered_item(p, cur[p], base[p], rules) for p in blocks["differ"]]
            items.sort(key=lambda it: it["path"])
    timing["check"] = time.monotonic() - clock
    attach_diffs(g, items, mp["dcur"], mp.get("dbase", ""))
    out = {"fs": have_cur, "base_fs": have_base, "items": items, "c_items": [], "c_found": None, "blocks": blocks,
           "lister": lister, "entries": len(cur) + len(base), "timing": timing}
    if pair:
        c_items = compare(target, session, {}, {}, rules, with_deleted=False, posix=pair[1]["os"] == "linux")
        for it in c_items:
            it["src"] = join(root, it["path"])
            it["path"] = it["src"]
            it["pair"] = pair[0]
        out["c_items"] = c_items
        out["c_found"] = pair[0]
    return out


def apply(g, req, dev, fs, mp):
    if mount_data(g, fs, dev["dwork"], mp["dwork"], True) is None:
        raise SystemExit("the data disk has no filesystem")
    done = 0
    for p in req.get("rm", []):
        g.rm_rf(mp["dwork"] + "/" + checked(p))
        done += 1
    if req.get("rescue"):
        system = req["systems"]["cs"]
        if system:
            mount_tree(g, system, mp["cs"])
        if not system or not g.is_dir(mp["cs"] + "/" + req["c_root"], followsymlinks=False):
            raise SystemExit("%s not found on the system disk" % req["c_root"])
        for r in req["rescue"]:
            dst = mp["dwork"] + "/" + checked(r["dst"])
            g.mkdir_p(dst.rsplit("/", 1)[0])
            g.cp_a(mp["cs"] + "/" + checked(r["src"]), dst)
            done += 1
    g.sync()
    return {"done": done}


def appliance_sh(g, script):
    # The Python binding only takes extended attribute values as text, so binary NTFS metadata goes through the appliance's own shell.
    out = g.debug("sh", [script + '; echo "rc=$?"'])
    body, _, rc = out.rstrip("\n").rpartition("rc=")
    if rc.strip() != "0":
        raise SystemExit("appliance command failed: " + body.strip()[-2000:])
    return body


def set_xattr(g, path, name, value):
    appliance_sh(g, "setfattr -h -n %s -v 0x%s %s" % (name, value.hex(), shlex.quote("/sysroot" + path)))


def get_xattr(g, path, name):
    try:
        return g.lgetxattr(path, name)
    except RuntimeError:
        return None


def lexists(g, path):
    try:
        g.lstatns(path)
        return True
    except RuntimeError:
        return False


def junction(target):
    sub = ("\\??\\" + target).encode("utf-16-le")
    prn = target.encode("utf-16-le")
    body = struct.pack("<HHHH", 0, len(sub), len(sub) + 2, len(prn)) + sub + b"\0\0" + prn + b"\0\0"
    return struct.pack("<IHH", 0xA0000003, len(body), 0) + body


def format_data(g, dev, linux):
    g.part_init(dev, "gpt")
    g.part_add(dev, "p", 2048, -34)
    g.part_set_gpt_type(dev, 1, LINUX_DATA if linux else BASIC_DATA)
    g.part_set_name(dev, 1, "data" if linux else "Basic data partition")
    g.mkfs("ext4" if linux else "ntfs", dev + "1", label="data" if linux else "Data")


def reparse_point(g, path):
    data = get_xattr(g, path, "system.ntfs_reparse_data")
    if not data:
        return None
    attrib = get_xattr(g, path, "system.ntfs_attrib") or b"\0\0\0\0"
    return data, bool(int.from_bytes(attrib[:4], "little") & 0x10)


def copy_tree(g, src, dst):
    is_dir = g.is_dir(src, followsymlinks=False)
    tree = walk(g, src) if is_dir else {}
    if get_xattr(g, src, "system.ntfs_attrib") is None:
        # A POSIX filesystem keeps owners, modes, ACLs and links where cp -a can see them.
        g.mkdir_p(dst.rsplit("/", 1)[0])
        g.cp_a(src, dst)
        files = sum(1 for e in tree.values() if e[0] == "r") if is_dir else 1
        size = sum(e[1] for e in tree.values() if e[0] == "r") if is_dir else g.lstatns(src)["st_size"]
        return {"files": files, "bytes": size, "links": 0, "warnings": []}
    # cp -a cannot see NTFS security descriptors and turns junctions into Linux symlinks, so both are carried over separately.
    reparse = {}
    for rel, entry in tree.items():
        if entry[0] == "l" and (rp := reparse_point(g, src + "/" + rel)):
            reparse[rel] = rp
    if g.is_symlink(src) and (rp := reparse_point(g, src)):
        reparse[""] = rp
    g.mkdir_p(dst.rsplit("/", 1)[0])
    if is_dir:
        g.mkdir_p(dst)
        g.cp_a(src + "/.", dst)
    elif "" not in reparse:
        g.cp_a(src, dst)
    for rel, (data, as_dir) in sorted(reparse.items()):
        d = dst + "/" + rel if rel else dst
        g.rm_rf(d)
        (g.mkdir if as_dir else g.touch)(d)
        set_xattr(g, d, "system.ntfs_reparse_data", data)
    if is_dir:
        where, name, dwhere = src, ".", dst
    else:
        where, name, dwhere = src.rsplit("/", 1)[0], src.rsplit("/", 1)[1], dst.rsplit("/", 1)[0]
    rename = "" if is_dir or name == dst.rsplit("/", 1)[1] else (
        " | sed 's|^# file: .*|# file: %s|'" % dst.rsplit("/", 1)[1].replace("|", "\\|"))
    warnings = []
    for attr in NTFS_META:
        body = appliance_sh(g, (
            "cd %s && getfattr -h %s -e hex -n %s %s 2>/dev/null%s > /tmp/nvd.meta; "
            "cd %s && setfattr -h --restore=/tmp/nvd.meta 2>&1 | head -5"
        ) % (shlex.quote("/sysroot" + where), "-R" if is_dir else "", attr, shlex.quote(name), rename,
             shlex.quote("/sysroot" + dwhere)))
        if body.strip():
            warnings.append("%s: %s" % (attr, body.strip()))
    files = sum(1 for e in tree.values() if e[0] == "r") if is_dir else 1
    size = sum(e[1] for e in tree.values() if e[0] == "r") if is_dir else g.lstatns(src)["st_size"]
    return {"files": files, "bytes": size, "links": len(reparse), "warnings": warnings}


def carry(g, req, dev, fs, mp):
    out = {"formatted": None, "items": []}
    system = req["systems"]["cs"]
    if system is None:
        raise SystemExit("no Windows or Linux system on the system disk")
    if not fs_parts(g, fs, dev["dw"]):
        format_data(g, dev["dw"], system["os"] == "linux")
        fs = g.list_filesystems()
        out["formatted"] = "ext4" if system["os"] == "linux" else "NTFS"
    if mount_data(g, fs, dev["dw"], mp["dw"], True) is None:
        raise SystemExit("the data disk has no filesystem")
    mount_tree(g, system, mp["cs"])
    for src, dst in req["carry"]:
        s = mp["cs"] + "/" + checked(src)
        d = mp["dw"] + "/" + checked(dst)
        if not lexists(g, s):
            out["items"].append({"src": src, "dst": dst, "missing": True})
            continue
        if g.is_symlink(s):
            # Already a junction from an earlier link, and copying it would replace the data disk folder with a link.
            out["items"].append({"src": src, "dst": dst, "linked": True})
            continue
        if lexists(g, d) and not req.get("refresh"):
            out["items"].append({"src": src, "dst": dst, "present": True})
            continue
        g.rm_rf(d)
        out["items"].append(dict(copy_tree(g, s, d), src=src, dst=dst))
    g.sync()
    return out


def subtree_spec(g, top, path):
    # Lists the parent with only this entry let through, so a path missing on one side compares as one new or deleted item.
    parent, _, name = path.rpartition("/")
    d = top
    for part in parent.split("/") if parent else []:
        d += "/" + part
        if not g.is_dir(d, followsymlinks=False):
            return None
    return (d, (), name) if lexists(g, d + "/" + name) else None


def under_any(path, tops):
    return any(path == t or path.startswith(t + "/") for t in tops)


def carry_scan(g, req, dev, fs, mp):
    rules = Rules(req["rules"])
    tmpdir = os.environ.get("TMPDIR", "/tmp")
    paths = req["paths"]
    system = req["systems"]["cs"]
    if system is None:
        raise SystemExit("no Windows or Linux system on the system disk")
    posix = system["os"] == "linux"
    mount_tree(g, system, mp["cs"])
    have_target = mount_tree(g, system, mp["ct"], swap=(dev["cs"], dev["ct"]), fs=fs)
    hashed = [""] if req["hash_all"] else req["hash_paths"]
    items, files, entries = [], [], {}
    specs, index = [], []
    for path in paths:
        for side, top in (("cur", mp["cs"]), ("base", mp["ct"] if have_target else None)):
            spec = subtree_spec(g, top, path) if top else None
            if spec:
                index.append((path, side))
                specs.append(spec)
    listed = dict(zip(index, walks(g, specs)))
    for path in paths:
        parent = path.rpartition("/")[0]
        pre = parent + "/" if parent else ""
        if "" in hashed or under_any(path, hashed):
            dirs = [path]
        else:
            dirs = [h for h in hashed if under_any(h, [path])]
        cur = listed.get((path, "cur"), {})
        base = listed.get((path, "base"), {})
        hc = {k[len(pre):]: v for k, v in hashes(g, mp["cs"], dirs, tmpdir).items() if k.startswith(pre)}
        hb = {k[len(pre):]: v for k, v in hashes(g, mp["ct"], dirs, tmpdir).items() if k.startswith(pre)} if have_target else {}
        for it in compare(base, cur, hb, hc, rules, prefix=pre, posix=posix):
            it["path"] = pre + it["path"]
            items.append(it)
        sub = "/" + parent if parent else ""
        found = unchanged_files(cur, base, hb, hc, mp["cs"] + sub, mp["ct"] + sub, pre, posix)
        files += found
        entries.update((key, (cur[key[len(pre):]], base[key[len(pre):]])) for *_, key in found)
    blocks = None
    if have_target and req.get("ranges") is not None:
        spart = system["mounts"][0][1]
        blocks = ctime_check(g, files) if posix else block_check(g, dev["cs"], spart, req["ranges"], files,
                                                                 dev["ct"], spart.replace(dev["cs"], dev["ct"], 1))
        if blocks:
            items += [tampered_item(p, *entries[p], rules) for p in blocks["differ"]]
    items.sort(key=lambda it: it["path"])
    attach_diffs(g, items, mp["cs"], mp["ct"], ("snapshot", "session"))
    return {"items": items, "blocks": blocks}


def carry_into(g, req, dev, fs, mp):
    system = req["systems"]["cs"]
    if system is None:
        raise SystemExit("no Windows or Linux system on the system disk")
    mount_tree(g, system, mp["cs"])
    mount_tree(g, system, mp["cn"], rw=True, swap=(dev["cs"], dev["cn"]))
    items = req["items"]
    for it in items:
        if not under_any(it["path"], req["paths"]):
            raise SystemExit("refusing to carry %r, which is outside the carryOnRevert paths" % it["path"])
    # Deletions first, then copies in path order, so a folder exists before anything lands inside it.
    for it in sorted(items, key=lambda it: (it["st"] != "D", it["path"])):
        p = checked(it["path"])
        g.rm_rf(mp["cn"] + "/" + p)
        if it["st"] != "D":
            copy_tree(g, mp["cs"] + "/" + p, mp["cn"] + "/" + p)
    g.sync()
    return {"done": len(items)}


def hive_values(g, node):
    return {g.hivex_value_key(v["hivex_value_h"]): g.hivex_value_value(v["hivex_value_h"]) for v in g.hivex_node_values(node)}


def describe(value):
    if value.startswith(b"DMIO:ID:") and len(value) == 24:
        return "partition " + str(uuid.UUID(bytes_le=value[8:]))
    if len(value) == 12:
        return "MBR partition"
    return safe(value.decode("utf-16-le", "replace").rstrip("\0"))


def mounted_devices(g, hive, letter, ours, rw):
    g.hivex_open(hive, write=rw)
    try:
        md = g.hivex_node_get_child(g.hivex_root(), "MountedDevices")
        if md == 0:
            raise SystemExit("MountedDevices is missing from the SYSTEM hive")
        vals = hive_values(g, md)
        key = "\\DosDevices\\%s:" % letter
        others = [k for k, v in vals.items() if v == ours and k != key and k.startswith("\\DosDevices\\")]
        if others:
            raise SystemExit("Windows already gave the data disk %s; set windows.letter to match" % others[0][-2:])
        cur = vals.get(key)
        if cur == ours:
            return ["drive %s: already points at the data disk" % letter]
        steps = []
        if cur is not None:
            if cur.startswith(b"DMIO:ID:") or len(cur) == 12:
                raise SystemExit("%s: belongs to another fixed volume (%s); pick another windows.letter" % (letter, describe(cur)))
            free = next((c for c in "ZYXWVUTSRQPONMLKJIHGFE" if "\\DosDevices\\%s:" % c not in vals), None)
            if free is None:
                raise SystemExit("no free drive letter to move %s: to" % letter)
            steps.append("move %s: (%s) to %s:" % (letter, describe(cur), free))
            if rw:
                g.hivex_node_set_value(md, "\\DosDevices\\%s:" % free, REG_BINARY, cur)
        steps.append("give drive %s: to the data disk (%s)" % (letter, describe(ours)))
        if rw:
            g.hivex_node_set_value(md, key, REG_BINARY, ours)
            g.hivex_commit(None)
        return steps
    finally:
        g.hivex_close()


def user_env(g, hive, user, values, rw):
    g.hivex_open(hive, write=rw)
    try:
        root = g.hivex_root()
        env = g.hivex_node_get_child(root, "Environment")
        cur = hive_values(g, env) if env else {}
        steps = []
        for k, v in sorted(values.items()):
            data = (v + "\0").encode("utf-16-le")
            if cur.get(k) == data:
                steps.append("%s: %s is already %s" % (user, k, v))
                continue
            steps.append("%s: set %s=%s" % (user, k, v))
            if rw:
                if not env:
                    env = g.hivex_node_add_child(root, "Environment")
                g.hivex_node_set_value(env, k, REG_EXPAND_SZ if "%" in v else REG_SZ, data)
        if rw:
            g.hivex_commit(None)
        return steps
    finally:
        g.hivex_close()


def link(g, req, dev, fs, mp):
    system = req["systems"]["cs"]
    if system is None:
        raise SystemExit("no Windows or Linux system on the system disk")
    if system["os"] == "linux":
        return link_linux(g, req, dev, fs, mp, system)
    rw = not req["dry_run"]
    letter = req["letter"]
    if not letter:
        raise SystemExit("the system disk runs Windows, so the data disk needs windows.letter and windows.carry")
    dparts = fs_parts(g, fs, dev["dd"])
    if not dparts or fs[dparts[0]] != "ntfs":
        raise SystemExit("the data disk has no NTFS filesystem yet; run carry first")
    if dparts[0] == dev["dd"] or g.part_get_parttype(dev["dd"]) != "gpt":
        raise SystemExit("the data disk needs a GPT partition table, which carry creates")
    guid = g.part_get_gpt_guid(dev["dd"], g.part_to_partnum(dparts[0]))
    g.mount_ro(dparts[0], mp["dd"])
    mount_tree(g, system, mp["cs"], rw)
    steps = []
    for src, dst in req["carry"]:
        s = mp["cs"] + "/" + checked(src)
        d = mp["dd"] + "/" + checked(dst)
        target = "%s:\\%s" % (letter, dst.replace("/", "\\"))
        on_data = lexists(g, d)
        want = junction(target) if g.is_dir(d, followsymlinks=False) else None
        exists = lexists(g, s)
        if want and get_xattr(g, s, "system.ntfs_reparse_data") == want:
            steps.append("%s already links to %s" % (src, target))
            continue
        if exists and not on_data:
            raise SystemExit("%s is not on the data disk yet, so its system disk copy stays; run carry first" % dst)
        acl = get_xattr(g, s, "system.ntfs_acl") if exists else None
        if exists:
            steps.append("delete the old %s" % src)
        if want:
            steps.append("link %s -> %s" % (src, target))
        if not rw:
            continue
        if exists:
            g.rm_rf(s)
        if want:
            g.mkdir_p(s.rsplit("/", 1)[0])
            g.mkdir(s)
            set_xattr(g, s, "system.ntfs_reparse_data", want)
            if acl:
                set_xattr(g, s, "system.ntfs_acl", acl)
    hive = g.case_sensitive_path(mp["cs"] + "/Windows/System32/config/SYSTEM")
    steps += mounted_devices(g, hive, letter, b"DMIO:ID:" + uuid.UUID(guid).bytes_le, rw)
    for user, values in sorted(req["user_env"].items()):
        hive = g.case_sensitive_path(mp["cs"] + "/Users/%s/NTUSER.DAT" % checked(user))
        steps += user_env(g, hive, user, values, rw)
    if rw:
        g.sync()
    return {"steps": steps}


def drop_values(g, hive, key, drop, rw):
    # The hivex calls cannot delete a value, so the key is rebuilt with every other value as it was.
    g.hivex_open(hive, write=rw)
    try:
        root = g.hivex_root()
        node = g.hivex_node_get_child(root, key)
        if not node:
            return []
        vals = [(g.hivex_value_key(v["hivex_value_h"]), g.hivex_value_type(v["hivex_value_h"]), g.hivex_value_value(v["hivex_value_h"]))
                for v in g.hivex_node_values(node)]
        gone = [k for k, _, v in vals if drop.get(k) == v]
        if not gone or not rw:
            return gone
        if g.hivex_node_children(node):
            raise SystemExit("%s has subkeys, so it cannot be rebuilt without %s" % (key, ", ".join(gone)))
        name = g.hivex_node_name(node)
        g.hivex_node_delete_child(node)
        node = g.hivex_node_add_child(root, name)
        for k, t, v in vals:
            if k not in gone:
                g.hivex_node_set_value(node, k, t, v)
        g.hivex_commit(None)
        return gone
    finally:
        g.hivex_close()


def tree_bytes(g, path, nested=()):
    if not g.is_dir(path, followsymlinks=False):
        return g.lstatns(path)["st_size"]
    return sum(e[1] for e in walk(g, path, [glob_escape(rel) for rel in nested]).values() if e[0] == "r")


def copy_back(g, req, root, data, target_of, is_ours, nest=None):
    # Shared by both systems: each carried entry comes back from the data disk in place of its link.
    rw = not req["dry_run"]
    dsts = nest if nest is not None else [d for _, d in req["carry"]]
    steps, todo, need, where = [], [], {}, {}
    for src, dst in req["carry"]:
        s = root + "/" + checked(src)
        d = data + "/" + checked(dst)
        target = target_of(dst)
        linked = is_ours(s, target)
        if lexists(g, s) and not linked:
            steps.append("%s %s" % (src, "links somewhere else, left alone" if g.is_symlink(s) else "is already on the system disk"))
            continue
        copy = req["copy"] and lexists(g, d)
        if not linked and not copy:
            continue
        # A carried file inside a carried folder goes back to its own place, not into the folder's copy.
        nested = {o[len(dst) + 1:] for o in dsts if o.startswith(dst + "/")}
        if copy:
            size = tree_bytes(g, d, nested)
            parent = s.rsplit("/", 1)[0]
            fsid = g.statvfs(parent)["fsid"]
            need[fsid] = need.get(fsid, 0) + size
            where[fsid] = parent
            steps.append("copy %s back to %s (%s)" % (target, src, human(size)))
        if linked:
            steps.append("remove the link %s -> %s%s" % (src, target, "" if copy or not req["copy"] else ", which is missing"))
        todo.append((s, d, copy, linked, nested))
    for fsid, size in need.items():
        st = g.statvfs(where[fsid])
        free = st["bavail"] * st["frsize"]
        total = st["blocks"] * st["frsize"]
        if size + min(64 << 20, total // 10) + total // 100 > free:
            msg = "the system disk has %s free, too little for the %s to copy back" % (human(free), human(size))
            if rw:
                raise SystemExit(msg)
            steps.append("!! " + msg)
    if rw:
        for s, d, copy, linked, nested in todo:
            # The copy lands next to the link first, so a failed copy leaves the link working.
            tmp = s + ".nixvirt-unlink"
            if copy:
                g.rm_rf(tmp)
                copy_tree(g, d, tmp)
                for rel in nested:
                    g.rm_rf(tmp + "/" + rel)
            if linked:
                g.rm_rf(s)
            if copy:
                g.mv(tmp, s)
    return steps, bool(todo)


def junction_target(data):
    # The substitute name Windows resolves, without its \??\ prefix.
    if not data or len(data) < 16 or U32(data, 0)[0] != 0xA0000003:
        return None
    off, size = U16(data, 8)[0], U16(data, 10)[0]
    name = data[16 + off:16 + off + size].decode("utf-16-le", "replace")
    return name[4:] if name.startswith("\\??\\") else name


def fstab_point(g, root):
    path = root + "/etc/fstab"
    if not g.is_file(path, followsymlinks=False):
        return None
    inside = False
    for ln in g.read_file(path).decode("utf-8", "replace").splitlines():
        if ln.strip() == FSTAB_BEGIN:
            inside = True
        elif ln.strip() == FSTAB_END:
            inside = False
        elif inside and len(ln.split()) >= 2:
            return ln.split()[1].rstrip("/")
    return None


def drop_env_windows(g, root, targets, rw):
    # Every profile is checked, since the entry that set a value may already be gone from the config.
    steps = []
    users = root + "/Users"
    if not g.is_dir(users, followsymlinks=False):
        return steps
    low = [t.lower() for t in targets]
    for name in sorted(g.ls(users)):
        home = users + "/" + name
        if g.is_symlink(home) or not g.is_dir(home, followsymlinks=False):
            continue
        hive = g.case_sensitive_path(home + "/NTUSER.DAT")
        if not g.is_file(hive, followsymlinks=False):
            continue
        g.hivex_open(hive, write=False)
        try:
            node = g.hivex_node_get_child(g.hivex_root(), "Environment")
            vals = hive_values(g, node) if node else {}
        finally:
            g.hivex_close()
        drop = {}
        for k, v in vals.items():
            text = v.decode("utf-16-le", "replace").rstrip("\0").rstrip("\\").lower()
            if any(text == t or text.startswith(t + "\\") for t in low):
                drop[k] = v
        if drop:
            steps += ["%s: remove %s" % (name, k) for k in drop_values(g, hive, "Environment", drop, rw)]
    return steps


def drop_env_linux(g, root, targets, rw):
    steps = []
    for ln in g.read_file(root + "/etc/passwd").decode("utf-8", "replace").splitlines():
        f = ln.split(":")
        if len(f) < 7 or not f[5].strip("/"):
            continue
        path = root + "/" + f[5].strip("/") + "/" + ENV_FILE
        if not g.is_file(path, followsymlinks=False):
            continue
        lines = g.read_file(path).decode("utf-8", "replace").splitlines()
        keep = [x for x in lines if not any(x.partition("=")[2] == t or x.partition("=")[2].startswith(t + "/") for t in targets)]
        if keep == lines:
            continue
        steps += ["%s: remove %s" % (f[0], x.partition("=")[0]) for x in lines if x not in keep]
        if rw:
            if keep:
                g.write(path, ("\n".join(keep) + "\n").encode())
            else:
                g.rm(path)
    return steps


def unlink_only(g, req, root, data, link_of, dest_of, target_of, is_ours, drop_env):
    # The link itself says where its data went, so this works whether or not the entry is still configured.
    rw = not req["dry_run"]
    config = dict(req["carry"])
    steps, entries, targets = [], [], {}
    for src in req["only"]:
        s = root + "/" + checked(src)
        target = link_of(s)
        dst = dest_of(target) if target else None
        if not dst and src in config and not lexists(g, s):
            dst, target = config[src], target_of(config[src])
        if not dst:
            steps.append("%s does not link into the data disk, left alone" % src)
            continue
        entries.append((src, checked(dst)))
        targets[dst] = target
    more, changed = copy_back(g, dict(req, carry=entries), root, data, targets.__getitem__, is_ours,
                              nest=[d for _, d in req["carry"]] + list(targets))
    # A program pointed at a folder that left the data disk would keep using the data disk copy.
    gone = drop_env(g, root, list(targets.values()), rw)
    if rw:
        g.sync()
    return {"steps": steps + more + gone, "changed": changed or bool(gone)}


def unlink(g, req, dev, fs, mp):
    system = req["systems"]["cs"]
    if system is None:
        raise SystemExit("no Windows or Linux system on the system disk")
    rw = not req["dry_run"]
    dparts = fs_parts(g, fs, dev["dd"])
    if not dparts or dparts[0] == dev["dd"]:
        raise SystemExit("the data disk has no partitioned filesystem")
    g.mount_ro(dparts[0], mp["dd"])
    mount_tree(g, system, mp["cs"], rw)
    root = mp["cs"]
    if system["os"] == "linux":
        point = req["mount_point"].rstrip("/")

        def is_ours(s, target):
            return g.is_symlink(s) and g.readlink(s) == target

        if req.get("only"):
            points = {point} | ({p} if (p := fstab_point(g, root)) else set())

            def link_of(s):
                t = g.readlink(s) if g.is_symlink(s) else ""
                return t if any(t.startswith(x + "/") for x in points) else None

            def dest_of(t):
                return t[len(next(x for x in points if t.startswith(x + "/"))) + 1:]

            return unlink_only(g, req, root, mp["dd"], link_of, dest_of, lambda dst: point + "/" + dst, is_ours, drop_env_linux)
        steps, changed = copy_back(g, req, root, mp["dd"], lambda dst: point + "/" + dst, is_ours)
        if fstab_block(g, root + "/etc/fstab", [], rw):
            steps.append("remove the data disk from /etc/fstab")
            changed = True
        for user in sorted(req["user_env"]):
            gone = set_linux_env(g, root, user, {}, rw)
            steps += gone
            changed = changed or bool(gone)
        if rw:
            g.sync()
        return {"steps": steps, "changed": changed}
    letter = req["letter"]
    guid = g.part_get_gpt_guid(dev["dd"], g.part_to_partnum(dparts[0]))
    ours = b"DMIO:ID:" + uuid.UUID(guid).bytes_le
    hive = g.case_sensitive_path(root + "/Windows/System32/config/SYSTEM")

    def is_ours(s, target):
        return (junction_target(get_xattr(g, s, "system.ntfs_reparse_data")) or "").lower() == target.lower()

    if req.get("only"):
        g.hivex_open(hive, write=False)
        try:
            md = g.hivex_node_get_child(g.hivex_root(), "MountedDevices")
            mapped = {k[-2].upper() for k, v in (hive_values(g, md) if md else {}).items() if v == ours and len(k) == 14}
        finally:
            g.hivex_close()
        mapped |= {letter.upper()} if letter else set()

        def link_of(s):
            t = junction_target(get_xattr(g, s, "system.ntfs_reparse_data"))
            return t if t and re.fullmatch(r"[A-Za-z]:\\.+", t) and t[0].upper() in mapped else None

        return unlink_only(g, req, root, mp["dd"], link_of, lambda t: t[3:].replace("\\", "/"),
                           lambda dst: "%s:\\%s" % (letter, dst.replace("/", "\\")), is_ours, drop_env_windows)
    steps, changed = copy_back(g, req, root, mp["dd"], lambda dst: "%s:\\%s" % (letter, dst.replace("/", "\\")), is_ours)
    key = "\\DosDevices\\%s:" % letter
    if drop_values(g, hive, "MountedDevices", {key: ours}, rw):
        steps.append("free drive %s: from the data disk" % letter)
        changed = True
    for user, values in sorted(req["user_env"].items()):
        hive = g.case_sensitive_path(root + "/Users/%s/NTUSER.DAT" % checked(user))
        drop = {k: (v + "\0").encode("utf-16-le") for k, v in values.items()}
        gone = drop_values(g, hive, "Environment", drop, rw)
        steps += ["%s: remove %s" % (user, k) for k in gone]
        changed = changed or bool(gone)
    if rw:
        g.sync()
    return {"steps": steps, "changed": changed}


FSTAB_BEGIN = "# nixvirt-data: begin, managed from the host"
FSTAB_END = "# nixvirt-data: end"
ENV_FILE = ".config/environment.d/60-nixvirt-data.conf"


def fstab_block(g, path, block, rw):
    # The data disk's lines sit between markers, so link can replace them and unlink can remove exactly them.
    text = g.read_file(path).decode("utf-8", "surrogateescape") if g.is_file(path) else ""
    kept, inside, had = [], False, False
    for ln in text.splitlines():
        if ln.strip() == FSTAB_BEGIN:
            inside = had = True
        elif ln.strip() == FSTAB_END:
            inside = False
        elif not inside:
            kept.append(ln)
    if not block and not had:
        return False
    new = "\n".join(kept + ([FSTAB_BEGIN] + block + [FSTAB_END] if block else [])) + "\n"
    if new == text:
        return False
    if rw:
        g.write(path, new.encode("utf-8", "surrogateescape"))
    return True


def home_of(g, root, user):
    for ln in g.read_file(root + "/etc/passwd").decode("utf-8", "replace").splitlines():
        f = ln.split(":")
        if len(f) >= 7 and f[0] == user and f[2].isdigit() and f[3].isdigit():
            return f[5].strip("/"), int(f[2]), int(f[3])
    raise SystemExit("the guest has no user %s in /etc/passwd" % user)


def set_linux_env(g, root, user, values, rw):
    # environment.d reaches systemd user services and the desktop session started from them. Empty values remove the file.
    home, uid, gid = home_of(g, root, user)
    path = root + "/" + checked(home) + "/" + ENV_FILE
    want = "".join("%s=%s\n" % kv for kv in sorted(values.items()))
    cur = g.read_file(path).decode("utf-8", "replace") if g.is_file(path, followsymlinks=False) else None
    if not values:
        if cur is None:
            return []
        if rw:
            g.rm(path)
        return ["%s: remove ~/%s" % (user, ENV_FILE)]
    if cur == want:
        return ["%s: %s already set" % (user, ", ".join(sorted(values)))]
    if rw:
        d = root + "/" + home
        for part in ENV_FILE.split("/")[:-1]:
            d += "/" + part
            if not lexists(g, d):
                g.mkdir(d)
                g.lchown(uid, gid, d)
                g.chmod(0o755, d)
            elif g.is_symlink(d):
                raise SystemExit("%s is a link in the guest, refusing to write through it" % d[len(root):])
        g.write(path, want.encode())
        g.lchown(uid, gid, path)
        g.chmod(0o644, path)
    return ["%s: set %s" % (user, ", ".join("%s=%s" % kv for kv in sorted(values.items())))]


def link_linux(g, req, dev, fs, mp, system):
    rw = not req["dry_run"]
    point = (req.get("mount_point") or "").rstrip("/")
    if not point:
        raise SystemExit("the system disk runs Linux, so the data disk needs linux.mountPoint and linux.carry")
    dparts = fs_parts(g, fs, dev["dd"])
    if not dparts or fs[dparts[0]] not in POSIX_FS:
        raise SystemExit("the data disk has no Linux filesystem yet; run carry first")
    g.mount_ro(dparts[0], mp["dd"])
    mount_tree(g, system, mp["cs"], rw)
    root = mp["cs"]
    steps = []
    for src, dst in req["carry"]:
        s = root + "/" + checked(src)
        d = mp["dd"] + "/" + checked(dst)
        target = point + "/" + dst
        if g.is_symlink(s) and g.readlink(s) == target:
            steps.append("%s already links to %s" % (src, target))
            continue
        exists = lexists(g, s)
        if exists and not lexists(g, d):
            raise SystemExit("%s is not on the data disk yet, so its system disk copy stays; run carry first" % dst)
        # Folders get a symlink. A carried file is only removed, since programs replace files by renaming over them.
        want = g.is_dir(d, followsymlinks=False)
        owner = g.lstatns(s if exists else s.rsplit("/", 1)[0])
        if exists:
            steps.append("delete the old %s" % src)
        if want:
            steps.append("link %s -> %s" % (src, target))
        if not rw:
            continue
        if exists:
            g.rm_rf(s)
        if want:
            g.mkdir_p(s.rsplit("/", 1)[0])
            g.ln_s(target, s)
            g.lchown(owner["st_uid"], owner["st_gid"], s)
    if not g.is_dir(root + point, followsymlinks=False):
        steps.append("create the mount point %s" % point)
        if rw:
            g.mkdir_p(root + point)
    line = "UUID=%s %s %s defaults,nofail,x-systemd.device-timeout=10s 0 2" % (g.vfs_uuid(dparts[0]), point, fs[dparts[0]])
    if fstab_block(g, root + "/etc/fstab", [line], rw):
        steps.append("mount the data disk at %s through /etc/fstab" % point)
    else:
        steps.append("/etc/fstab already mounts the data disk at %s" % point)
    for user, values in sorted(req["user_env"].items()):
        steps += set_linux_env(g, root, user, values, rw)
    if rw:
        g.sync()
    return {"steps": steps}


ALIGN = 2048
GPT_TAIL = 34
RECOVERY = "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC"
SWAP = "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"


def partdev(dev, num):
    return "%s%d" % (dev, num)


def disk_layout(g, dev):
    try:
        kind = g.part_get_parttype(dev)
    except RuntimeError:
        return None
    if kind != "gpt":
        raise SystemExit("only GPT disks can be resized (found %s)" % kind)
    ss = g.blockdev_getss(dev)
    parts = []
    for p in g.part_list(dev):
        n = p["part_num"]
        try:
            fs = g.vfs_type(partdev(dev, n))
        except RuntimeError:
            fs = ""
        parts.append({
            "num": n, "start": p["part_start"] // ss, "end": p["part_end"] // ss, "fs": fs,
            "type": g.part_get_gpt_type(dev, n), "guid": g.part_get_gpt_guid(dev, n),
            "attrs": g.part_get_gpt_attributes(dev, n), "name": g.part_get_name(dev, n),
        })
    return {"ss": ss, "sectors": g.blockdev_getsize64(dev) // ss, "parts": sorted(parts, key=lambda p: p["start"])}


RESIZABLE = {"ntfs", "ext2", "ext3", "ext4", "btrfs", "xfs", "LVM2_member"}


def is_lv(g, device):
    try:
        g.lvm_canonical_lv_name(device)
        return True
    except RuntimeError:
        return False


def holds(g, pv, lv):
    vg = g.lvm_canonical_lv_name(lv).split("/")[2]
    uuids = {u.replace("-", "") for u in g.vgpvuuids(vg)}
    return any(x["pv_name"] == pv and x["pv_uuid"].replace("-", "") in uuids for x in g.pvs_full())


def resize_target(g, dev, mountpoint, lay, kind):
    parts = [p for p in lay["parts"] if p["fs"] in RESIZABLE]
    if kind == "data":
        return parts[0] if parts else None
    for p in parts:
        if p["fs"] != "ntfs":
            continue
        g.mount_ro(partdev(dev, p["num"]), mountpoint)
        try:
            found = g.is_dir(mountpoint + "/Windows", followsymlinks=False)
        finally:
            g.umount(mountpoint)
        if found:
            return p
    # A Linux root is found by inspection, on a partition or on a logical volume in an LVM partition.
    for root in g.inspect_os():
        device = device_of(root)
        for p in parts:
            pd = partdev(dev, p["num"])
            if device == pd:
                return p
            if p["fs"] == "LVM2_member" and is_lv(g, device) and holds(g, pd, device):
                return dict(p, lv=g.lvm_canonical_lv_name(device))
    return None


def fs_minimum(g, target, part, mountpoint, size):
    kind = target["fs"]
    if kind == "btrfs":
        g.mount_ro(part, mountpoint)
        try:
            # The kernel refuses to shrink btrfs below 256 MiB whatever its contents.
            return max(g.vfs_minimum_size(part), 256 << 20)
        finally:
            g.umount(mountpoint)
    if kind in ("xfs", "LVM2_member"):
        return size
    return g.vfs_minimum_size(part)


def grow_fs(g, target, part, mountpoint, force):
    kind = target["fs"]
    if kind == "ntfs":
        g.ntfsresize(part, force=force)
    elif kind.startswith("ext"):
        g.e2fsck(part, correct=True)
        g.resize2fs(part)
    elif kind in ("btrfs", "xfs"):
        g.mount(part, mountpoint)
        if kind == "btrfs":
            g.btrfs_filesystem_resize(mountpoint)
        else:
            g.xfs_growfs(mountpoint, datasec=True)
        g.umount(mountpoint)
    else:
        g.pvresize(part)
        g.lvresize_free(target["lv"], 100)
        grow_fs(g, {"fs": g.vfs_type(target["lv"])}, target["lv"], mountpoint, force)


def shrink_fs(g, target, part, size, mountpoint, force):
    kind = target["fs"]
    if kind == "ntfs":
        g.ntfsresize(part, size=size, force=force)
    elif kind.startswith("ext"):
        g.e2fsck(part, correct=True)
        g.resize2fs_size(part, size >> 20 << 20)
    elif kind == "btrfs":
        g.mount(part, mountpoint)
        g.btrfs_filesystem_resize(mountpoint, size=size >> 20 << 20)
        g.umount(mountpoint)
    else:
        raise SystemExit("%s cannot shrink" % kind)


def layout_plan(lay, target, new_bytes, minimum):
    ss = lay["ss"]
    sectors = new_bytes // ss
    cursor = sectors - GPT_TAIL + 1
    moves = []
    for p in reversed([p for p in lay["parts"] if p["start"] > target["start"]]):
        size = p["end"] - p["start"] + 1
        start = (cursor - size) // ALIGN * ALIGN
        moves.append({"num": p["num"], "from": p["start"], "to": start, "size": size, "type": p["type"]})
        cursor = start
    moves.reverse()
    end = cursor - 1
    nbytes = (end - target["start"] + 1) * ss
    old = (target["end"] - target["start"] + 1) * ss
    # The guest needs working room beyond its files, for a page file, updates and logs.
    need = minimum + (64 << 20) + minimum // 100
    problem = None
    risks = []
    if end <= target["start"]:
        problem = "the disk would be too small for the partitions behind the resized one"
    elif nbytes < old and nbytes < minimum:
        problem = "its files need at least %s, so the disk can shrink to about %s at most" % (
            human(minimum), human(new_bytes + minimum - nbytes))
    elif nbytes < old and nbytes < need:
        risks.append("only %s would stay free on partition %d, too little for the guest to keep working" % (
            human(nbytes - minimum), target["num"]))
    return {"sectors": sectors, "end": end, "bytes": nbytes, "old_bytes": old, "minimum": minimum,
            "moves": moves, "problem": problem, "risks": risks, "unchecked": False, "ss": ss}


def resize_plan(g, req, dev, fs, mp):
    d = dev["disk"]
    lay = disk_layout(g, d)
    if lay is None:
        return {"layout": None}
    target = resize_target(g, d, mp["disk"], lay, req["kind"])
    if target is None:
        raise SystemExit("no %s partition to resize" % ("Windows or Linux root" if req["kind"] == "system" else "data"))
    old = (target["end"] - target["start"] + 1) * lay["ss"]
    try:
        minimum = fs_minimum(g, target, partdev(d, target["num"]), mp["disk"], old)
    except RuntimeError as e:
        raise SystemExit("cannot read the filesystem on partition %d (%s); boot the guest and shut it down fully, then retry"
                         % (target["num"], str(e).strip().splitlines()[-1]))
    plan = layout_plan(lay, target, req["bytes"], minimum)
    plan["fs"], plan["lv"] = target["fs"], target.get("lv")
    if target["fs"] in ("xfs", "LVM2_member") and plan["bytes"] < old:
        plan["problem"] = "%s can only grow" % ("XFS" if target["fs"] == "xfs" else "an LVM physical volume")
    # The minimum-size query ignores the check flag that every ntfsresize leaves behind, so ask ntfsresize itself before changing anything.
    if target["fs"] == "ntfs" and "scheduled for check" in g.debug("sh", ["ntfsresize --no-action --info %s 2>&1; true" % partdev(d, target["num"])]):
        plan["unchecked"] = True
        plan["risks"].append("Windows has not checked partition %d since its last resize or an unclean shutdown; "
                             "booting Windows once and shutting it down clears this" % target["num"])
    return {"layout": lay, "target": target["num"], "plan": plan}


def recreate(g, dev, p, start, end, ss):
    # Same start, type, GUID and attributes: Windows finds its volumes by partition GUID, so C: and the recovery partition keep their identity.
    g.part_del(dev, p["num"])
    g.part_add(dev, "p", start, end)
    num = next((x["part_num"] for x in g.part_list(dev) if x["part_start"] // ss == start), None)
    if num != p["num"]:
        raise SystemExit("partition %d came back as number %s" % (p["num"], num))
    g.part_set_gpt_type(dev, num, p["type"])
    g.part_set_gpt_guid(dev, num, p["guid"])
    g.part_set_gpt_attributes(dev, num, p["attrs"])
    if p["name"]:
        g.part_set_name(dev, num, p["name"])


def move_partition(g, dev, p, to, ss):
    if to == p["start"]:
        return
    size = (p["end"] - p["start"] + 1) * ss
    shift = (to - p["start"]) * ss
    # The copy runs forwards, so a move up by less than the partition's size goes in chunks from the end,
    # each read before the next chunk overwrites it.
    step = shift if 0 < shift < size else size
    offsets = list(range(0, size, step))
    if shift > 0:
        offsets.reverse()
    src = partdev(dev, p["num"])
    for off in offsets:
        g.copy_device_to_device(src, dev, srcoffset=off, destoffset=to * ss + off, size=min(step, size - off))
    g.blockdev_flushbufs(dev)
    recreate(g, dev, p, to, to + size // ss - 1, ss)


def resize_apply(g, req, dev, fs, mp):
    d = dev["disk"]
    plan, phase = req["plan"], req["phase"]
    before = {p["num"]: p for p in req["layout"]["parts"]}
    target = before[req["target"]]
    if phase in ("grow", "fixgpt"):
        g.part_expand_gpt(d)
    # parted refuses to change a partition an active volume group holds open.
    g.vg_activate_all(False)
    lay = disk_layout(g, d)
    ss = lay["ss"]
    if phase in ("grow", "shrink"):
        if {n: (p["start"], p["end"]) for n, p in before.items()} != {p["num"]: (p["start"], p["end"]) for p in lay["parts"]}:
            raise SystemExit("the partition table changed since the plan; nothing was modified")
        sums = {m["num"]: g.checksum_device("sha256", partdev(d, m["num"])) for m in plan["moves"]}
        if phase == "grow":
            for m in reversed(plan["moves"]):
                move_partition(g, d, before[m["num"]], m["to"], ss)
            g.part_resize(d, target["num"], plan["end"])
            g.vg_activate_all(True)
            grow_fs(g, dict(target, lv=plan["lv"]), partdev(d, target["num"]), mp["disk"], plan["unchecked"])
        else:
            shrink_fs(g, target, partdev(d, target["num"]), plan["bytes"], mp["disk"], plan["unchecked"])
            recreate(g, d, target, target["start"], plan["end"], ss)
            for m in plan["moves"]:
                move_partition(g, d, before[m["num"]], m["to"], ss)
        for num, digest in sums.items():
            if g.checksum_device("sha256", partdev(d, num)) != digest:
                raise SystemExit("partition %d does not match its copy after the move" % num)
        lay = disk_layout(g, d)
    now = {p["num"]: p for p in lay["parts"]}
    wanted = [(target["num"], target["start"], plan["end"])] + [(m["num"], m["to"], m["to"] + m["size"] - 1) for m in plan["moves"]]
    for num, start, end in wanted:
        p = now.get(num)
        if not p or (p["start"], p["end"]) != (start, end) or (p["type"], p["guid"], p["attrs"]) != (
                before[num]["type"], before[num]["guid"], before[num]["attrs"]):
            raise SystemExit("partition %d is not where the plan put it" % num)
    g.vg_activate_all(True)
    g.mount_ro(plan["lv"] or partdev(d, target["num"]), mp["disk"])
    if req["kind"] == "system" and plan["fs"] == "ntfs":
        ok = g.is_dir(mp["disk"] + "/Windows", followsymlinks=False)
    else:
        ok = len(g.readdir(mp["disk"])) > 2
    g.umount(mp["disk"])
    if not ok:
        raise SystemExit("the resized filesystem does not show its files")
    g.sync()
    return {"layout": lay}


def trim(g, req, dev, fs, mp):
    out = []
    for p in fs_parts(g, fs, dev["disk"]) + [lv for lv in g.lvs() if lv in fs and on_drive(g, lv, dev["disk"])]:
        try:
            g.mount(p, mp["disk"])
        except RuntimeError as e:
            out.append({"part": p, "fs": fs[p], "error": str(e).strip().splitlines()[-1]})
            continue
        error = None
        try:
            g.fstrim(mp["disk"])
        except RuntimeError as e:
            error = str(e).strip().splitlines()[-1]
        g.umount(mp["disk"])
        g.mount_ro(p, mp["disk"])
        if not g.readdir(mp["disk"]):
            raise SystemExit("%s shows no files after the trim" % p)
        g.umount(mp["disk"])
        out.append({"part": p, "fs": fs[p], "error": error})
    g.sync()
    return {"parts": out}


def line_for(it, width):
    if it["type"] == "d":
        extra = "%s, %d file%s" % (human(it["size"]), it["files"], "" if it["files"] == 1 else "s")
        flagged = sum(it.get("flagged", {}).values())
        if flagged:
            extra += ", %d flagged" % flagged
        return "  %s  %-*s  %s" % (it["st"], width, safe(it["path"]) + "/", extra)
    note = ""
    if it["reason"] == "content":
        note = "  same size and date, different content"
    elif it["reason"] == "mode":
        note = "  permissions %o -> %o" % (it["old_mode"], it["mode"])
    elif it["reason"] == "type":
        note = "  type changed"
    elif it["reason"] == "link":
        note = "  link now -> " + safe(it.get("link") or "")
    elif it["type"] == "l":
        note = "  link -> " + safe(it.get("link") or "")
    size = human(it["size"]) if it["type"] == "r" else ""
    return "  %s  %-*s  %8s%s" % (it["st"], width, safe(it["path"]), size, note)


def group_key(path):
    return "/".join(path.split("/")[:2])


def section(title, items, limit=12):
    if not items:
        return []
    width = min(60, max(len(safe(it["path"])) + 1 for it in items))
    lines = [title] + [line_for(it, width) for it in items[:limit]]
    if len(items) > limit:
        lines.append("  ... and %d more ([v] lists everything)" % (len(items) - limit))
    return lines


def grouped(title, items, key=group_key):
    if not items:
        return []
    groups = {}
    for it in items:
        g = groups.setdefault(key(it["path"]), {"N": 0, "M": 0, "D": 0, "bytes": 0})
        g[it["st"]] += max(it["files"], 1)
        g["bytes"] += it["size"] if it["st"] != "D" else 0
    width = min(50, max(len(safe(k)) for k in groups))
    lines = [title]
    for k in sorted(groups):
        g = groups[k]
        parts = []
        if g["M"]:
            parts.append("%d changed" % g["M"])
        if g["N"]:
            parts.append("%d new" % g["N"])
        if g["D"]:
            parts.append("%d deleted" % g["D"])
        size = human(g["bytes"]) if g["bytes"] else ""
        lines.append(("  %-*s  %-24s %s" % (width, safe(k), ", ".join(parts), size)).rstrip())
    return lines


def block_line(blocks):
    if not blocks["complete"]:
        if not blocks["checked"]:
            return "change time check: no file with its old size and date has a new change time"
        return "change time check: %d file(s) with their old size and date have a new change time; each was compared by content" % (
            blocks["checked"])
    if not blocks["suspects"]:
        return "block check: no file with its old size and date had a written block or MFT record"
    return "block check: %d file(s) with their old size and date sat in written blocks, %d needed a full comparison" % (
        blocks["suspects"], blocks["checked"])


def unexplained_limit(items):
    # NTFS rewrites its log, MFT records and indexes for every change, which no file accounts for.
    return (128 << 20) + (16 << 10) * len(items)


def render(dom, state, titles):
    items = state["items"]
    lines = []
    if state["rev0_time"]:
        lines.append("%s  data disk: changes since rev0 (kept %s)" % (dom, state["rev0_time"]))
    else:
        lines.append("%s  data disk: no kept revision yet, everything counts as new" % dom)
    if not state["fs"]:
        lines.append("the data disk has no filesystem yet")
    written = state["written"]
    blocks = state.get("blocks")
    if written is not None:
        explained = sum(it["alloc"] for it in items if it["st"] != "D")
        trimmed = " and %s trimmed" % human(state["trimmed"]) if state["trimmed"] else ""
        lines.append("host check: %s written%s since rev0, listed files account for %s" % (human(written), trimmed, human(explained)))
        if blocks:
            lines.append(block_line(blocks))
        # Only the NTFS block check maps raw disk writes to files, so elsewhere unexplained bytes stay worth a look.
        if (not blocks or not blocks["complete"]) and state["base_fs"] and written - explained > unexplained_limit(items):
            lines.append("  !! %s written that the listed files do not explain; [h] hashes every file to find it"
                         % human(written - explained))
    if blocks and not blocks["clean"]:
        lines.append("  !! the data disk's NTFS journal was not closed cleanly (a crash or forced power off). Windows replays it at "
                     "its next boot, which can change files this review cannot see; boot and shut down cleanly, then review again")
    tampered = [it for it in items if it["reason"] == "content"]
    live = [it for it in items if it["st"] != "D" and it["reason"] != "content"]
    blocks = [section(TAMPERED, tampered)]
    blocks += [section(t, [it for it in live if it["flag"] == t]) for t in titles]
    blocks += [
        grouped("ADDED", [it for it in live if not it["flag"] and it["st"] == "N"]),
        grouped("CHANGED", [it for it in live if not it["flag"] and it["st"] == "M"]),
        grouped("DELETED", [it for it in items if it["st"] == "D"]),
        section("LEFT ON THE SYSTEM DISK (lost on revert)", state["c_items"]),
    ]
    for block in blocks:
        if block:
            lines.append("")
            lines.extend(block)
    if not items and not state["c_items"]:
        lines.append("no file changes")
    return "\n".join(lines)


def details(state):
    lines = ["data disk: every change"]
    for it in state["items"]:
        extra = ""
        if it["st"] == "M" and it["reason"] in ("size", "date"):
            extra = "  (%s changed; was %s)" % (it["reason"], human(it.get("old_size", 0)))
        lines.append(line_for(it, 60) + extra)
    if state["c_items"]:
        lines += ["", "LEFT ON THE SYSTEM DISK"] + [line_for(it, 60) for it in state["c_items"]]
    diffs = [it for it in state["items"] if it.get("diff")]
    if diffs:
        lines += ["", "DIFFS OF FLAGGED TEXT FILES"]
        for it in diffs:
            lines += [""] + [safe(ln) for ln in it["diff"]]
    return "\n".join(lines)


def numbered(items):
    width = min(60, max(len(safe(it["path"])) + 1 for it in items))
    return "\n".join("%4d %s" % (n, line_for(it, width)) for n, it in enumerate(items, 1))


class Review:
    def __init__(self, cfg, disk, args):
        self.cfg = cfg
        self.disk = disk
        self.spec = disk.spec
        self.pairs = args.c_pair or []
        self.ex = None
        self.state = None
        self.rescued = set()
        self.hash_all = getattr(args, "hash_all", False)
        self.rules = {"source_paths": self.spec.get("sourcePaths", []), "highlight": self.spec.get("highlight", {})}
        self.titles = Rules(self.rules).titles()

    def drives(self, with_c):
        drives = [self.ex.drive("dwork" if "dwork" in self.ex.socks else "dcur", "dcur")]
        if "dbase" in self.ex.socks:
            drives.append(self.ex.drive("dbase"))
        if with_c:
            for i in range(len(self.pairs)):
                drives += [self.ex.drive("cs%d" % i, system=True), self.ex.drive("ct%d" % i)]
        return drives

    def c_exclude(self):
        # Carried paths already live on the data disk, and carryOnRevert paths reach the fresh layer, so the revert loses neither.
        root = (self.spec.get("rescueRoot") or "").strip("/") + "/"
        kept = list(guest_config(self.spec)["carry"])
        kept += self.cfg.get("carry", {}).get(self.disk.dom, {}).get("paths", [])
        carried = [k[len(root):] for k in kept if k.startswith(root)]
        return self.spec.get("rescueExclude", []) + [re.sub(r"([*?[])", r"[\1]", p) for p in carried]

    def scan(self, with_c=False):
        # Remembered per kind of scan, so the next one can say roughly how long it will take.
        history = os.path.join(self.disk.revs, ".last-scan")
        kind = "hash" if self.hash_all else "with system disk" if with_c else "data disk"
        try:
            with open(history) as f:
                past = json.load(f)
        except (OSError, ValueError):
            past = {}
        expected = past.get(kind)
        print("scanning %s ...%s" % ("and hashing every file on the data disk" if self.hash_all else "the data disk",
                                     " (took %s last time)" % seconds(expected) if expected else ""), flush=True)
        cur = self.disk.work if os.path.exists(self.disk.work) else self.disk.image
        rev0 = self.disk.rev(0)
        have_rev0 = os.path.exists(rev0)
        diff = {"written": None, "trimmed": 0}

        def late():
            # Runs while the worker starts and reads the data disk's table, which takes longer.
            ranges, diff["written"], diff["trimmed"] = changed_ranges(cur, rev0) if have_rev0 else (None, None, 0)
            return {"ranges": ranges}

        started = time.monotonic()
        show = Progress(expected)
        try:
            res = self.ex.call({
                "op": "scan",
                "drives": self.drives(with_c),
                "hash_paths": self.spec.get("hashPaths", []),
                "hash_all": self.hash_all,
                "rules": self.rules,
                "c_pairs": list(range(len(self.pairs))) if with_c else [],
                "c_root": self.spec.get("rescueRoot"),
                "c_exclude": self.c_exclude(),
            }, late=late, show=show)
        finally:
            show.close()
        took = time.monotonic() - started
        if os.path.isdir(self.disk.revs):
            past[kind] = took
            with open(history, "w") as f:
                json.dump(past, f)
        how = "the data disk listed from its MFT" if res["lister"] == "mft" else "the data disk listed through " + res["lister"]
        print("scanned %s entries in %s (%s, listing %.1f s, block check %.1f s)"
              % (format(res["entries"], ","), seconds(took), how, res["timing"]["list"], res["timing"]["check"]), flush=True)
        state = {
            "items": res["items"],
            "fs": res["fs"],
            "base_fs": res["base_fs"],
            "blocks": res["blocks"],
            "written": diff["written"],
            "trimmed": diff["trimmed"],
            "rev0_time": datetime.fromtimestamp(os.stat(rev0).st_mtime).strftime("%Y-%m-%d %H:%M") if have_rev0 else None,
            "c_items": res["c_items"] if with_c else (self.state["c_items"] if self.state else []),
            "c_pair": res["c_found"] if with_c else (self.state["c_pair"] if self.state else None),
        }
        state["c_items"] = [it for it in state["c_items"] if it["src"] not in self.rescued]
        self.state = state

    def ensure_work(self):
        if "dwork" not in self.ex.socks:
            reflink(self.disk.image, self.disk.work)
            self.ex.start("dwork", self.disk.work, "raw", ro=False)

    def prune(self):
        cands = [it for it in self.state["items"] if it["st"] != "D"]
        if not cands:
            print("nothing to prune")
            return
        pager(numbered(cands))
        picked = parse_selection(ask("numbers to delete from the data disk (e.g. 1 3 5-7, empty cancels): ") or "", len(cands))
        if not picked:
            print("nothing deleted")
            return
        if not confirm("delete %d item(s) from the data disk?" % len(picked)):
            return
        self.ensure_work()
        self.ex.call({"op": "apply", "drives": [self.ex.drive("dwork", ro=False)], "rm": [cands[n - 1]["path"] for n in picked]})
        self.scan()

    def rescue(self):
        cands = self.state["c_items"]
        if not cands:
            print("nothing left on the system disk to rescue")
            return
        pager(numbered(cands))
        picked = parse_selection(ask("numbers to copy to the data disk (e.g. 1 3 5-7, 'all', empty cancels): ") or "", len(cands))
        if not picked:
            print("nothing copied")
            return
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        chosen = [cands[n - 1] for n in picked]
        self.ensure_work()
        self.ex.call({
            "op": "apply",
            "drives": [self.ex.drive("dwork", ro=False), self.ex.drive("cs%d" % self.state["c_pair"], "cs", system=True)],
            "c_root": self.spec.get("rescueRoot"),
            "rescue": [{"src": it["src"], "dst": "Rescued/%s/%s" % (stamp, it["src"])} for it in chosen],
        })
        self.rescued.update(it["src"] for it in chosen)
        print("copied %d item(s) to Rescued/%s on the data disk" % (len(chosen), stamp))
        self.scan()

    def keep(self):
        disk = self.disk
        changed = bool(self.state["items"]) or "dwork" in self.ex.socks
        if "dwork" in self.ex.socks:
            self.ex.stop("dwork")
            require_off(disk.dom)
            match_owner(disk.image, disk.work)
            os.replace(disk.work, disk.image)
        rotate(disk, changed)
        if changed:
            print("%s: kept the data disk as rev0 (older revisions shifted, %d kept)" % (disk.dom, disk.spec["keep"]))
        else:
            print("%s: no file changes; rev0 refreshed in place" % disk.dom)

    def discard(self):
        disk = self.disk
        if not os.path.exists(disk.rev(0)):
            print("no kept revision to go back to")
            return False
        if not confirm("discard every data disk change since rev0 (the replaced state is kept as 'discarded')?"):
            return False
        replace_image(disk, disk.rev(0))
        print("%s: the data disk is back at rev0; bring the discarded state back with: nixvirt-data restore %s discarded"
              % (disk.dom, disk.dom))
        return True

    def run(self, interactive=True, show_all=False):
        disk = self.disk
        self.ex = Exports(self.cfg, disk.dom)
        try:
            self.ex.start("dcur", disk.image, "raw")
            if os.path.exists(disk.rev(0)):
                self.ex.start("dbase", disk.rev(0), "raw")
            if not self.spec.get("rescueRoot"):
                self.pairs = []
            for i, (live, base) in enumerate(self.pairs):
                self.ex.start("cs%d" % i, live, image_info(live)["format"])
                self.ex.start("ct%d" % i, base, image_info(base)["format"])
            self.scan(with_c=bool(self.pairs))
            if not interactive:
                print()
                print(render(disk.dom, self.state, self.titles))
                if show_all:
                    print()
                    print(details(self.state))
                return 0
            st = self.state
            if not st["items"] and not st["c_items"] and not st["written"]:
                print("%s: data disk unchanged since rev0" % disk.dom)
                return 0
            while True:
                print()
                print(render(disk.dom, self.state, self.titles))
                print()
                menu = ["[k]eep"]
                if os.path.exists(disk.rev(0)):
                    menu.append("[d]iscard")
                menu.append("[p]rune")
                if self.state["c_items"]:
                    menu.append("[r]escue from the system disk")
                menu += ["[v]iew", "[h]ash everything", "[a]bort"]
                choice = (ask("  ".join(menu) + ": ") or "a").lower()[:1]
                if choice == "k":
                    self.keep()
                    return 0
                if choice == "d" and self.discard():
                    return 0
                if choice == "p":
                    self.prune()
                elif choice == "r":
                    self.rescue()
                elif choice == "v":
                    pager(details(self.state))
                elif choice == "h":
                    self.hash_all = True
                    self.scan()
                elif choice == "a":
                    print("aborted; the data disk was not changed")
                    return ABORTED
        finally:
            self.ex.close()
            if os.path.exists(disk.work):
                os.unlink(disk.work)


class CarryReview:
    def __init__(self, cfg, dom, spec, live, target):
        self.cfg, self.dom, self.spec, self.live, self.target = cfg, dom, spec, live, target
        self.rules = {"source_paths": spec.get("sourcePaths", []), "highlight": spec.get("highlight", {})}
        self.titles = Rules(self.rules).titles()
        self.hash_all = False
        self.items = []
        self.blocks = None
        self.left_out = set()
        self.ex = None

    def scan(self):
        print("scanning the carryOnRevert folders%s ..." % (" and hashing every file in them" if self.hash_all else ""), flush=True)
        res = self.ex.call({
            "op": "carry_scan",
            "drives": [self.ex.drive("cs", system=True), self.ex.drive("ct")],
            "paths": self.spec["paths"],
            "rules": self.rules,
            "hash_paths": self.spec.get("hashPaths", []),
            "hash_all": self.hash_all,
            "ranges": layer_ranges(self.live, self.target),
        })
        self.items, self.blocks = res["items"], res["blocks"]

    def group(self, path):
        return max((p for p in self.spec["paths"] if under_any(path, [p])), key=len, default=path)

    def render(self):
        chosen = [it for it in self.items if it["path"] not in self.left_out]
        tampered = [it for it in chosen if it["reason"] == "content"]
        live = [it for it in chosen if it["st"] != "D" and it["reason"] != "content"]
        lines = ["%s: changes in the carryOnRevert folders since the snapshot, which a plain revert loses" % self.dom]
        if self.blocks:
            lines.append(block_line(self.blocks))
            if not self.blocks["clean"]:
                lines.append("  !! the session's NTFS journal was not closed cleanly (a crash or forced power off), "
                             "so its newest changes may be missing from what is carried")
        blocks = [section(TAMPERED, tampered)]
        blocks += [section(t, [it for it in live if it["flag"] == t]) for t in self.titles]
        blocks += [
            grouped("ADDED", [it for it in live if not it["flag"] and it["st"] == "N"], self.group),
            grouped("CHANGED", [it for it in live if not it["flag"] and it["st"] == "M"], self.group),
            grouped("DELETED (also deleted in the fresh layer)", [it for it in chosen if it["st"] == "D"], self.group),
            section("LEFT OUT (reverts with everything else)", [it for it in self.items if it["path"] in self.left_out]),
        ]
        for block in blocks:
            if block:
                lines.append("")
                lines.extend(block)
        return "\n".join(lines)

    def details(self):
        lines = ["carryOnRevert: every change"] + [line_for(it, 60) for it in self.items]
        diffs = [it for it in self.items if it.get("diff")]
        if diffs:
            lines += ["", "DIFFS OF FLAGGED TEXT FILES"]
            for it in diffs:
                lines += [""] + [safe(ln) for ln in it["diff"]]
        return "\n".join(lines)

    def leave_out(self):
        pager(numbered(self.items))
        picked = parse_selection(ask("numbers to leave out so they revert (e.g. 1 3 5-7, empty leaves nothing out): ") or "",
                                 len(self.items))
        self.left_out = {self.items[n - 1]["path"] for n in picked or []}

    def run(self, into):
        self.ex = Exports(self.cfg, self.dom)
        try:
            self.ex.start("cs", self.live, image_info(self.live)["format"])
            self.ex.start("ct", self.target, image_info(self.target)["format"])
            self.scan()
            if not self.items:
                print("%s: nothing changed in the carryOnRevert folders" % self.dom)
                return 0
            if into is None:
                print()
                print(self.render())
                return 0
            while True:
                print()
                print(self.render())
                print()
                choice = (ask("[c]arry into the fresh layer  [l]eave some out  [n]one, revert them too  [v]iew  "
                              "[h]ash everything  [a]bort: ") or "a").lower()[:1]
                if choice == "c":
                    break
                if choice == "l":
                    self.leave_out()
                elif choice == "n":
                    print("nothing carried; the revert discards these changes")
                    return 0
                elif choice == "v":
                    pager(self.details())
                elif choice == "h":
                    self.hash_all = True
                    self.scan()
                elif choice == "a":
                    print("aborted; nothing was carried")
                    return ABORTED
        finally:
            self.ex.close()
        chosen = [{"path": it["path"], "st": it["st"]} for it in self.items if it["path"] not in self.left_out]
        if not chosen:
            print("everything was left out; the revert discards these changes")
            return 0
        run(["qemu-img", "create", "-q", "-f", "qcow2", "-b", self.target, "-F", image_info(self.target)["format"], into])
        ex = Exports(self.cfg, self.dom)
        try:
            ex.start("cs", self.live, image_info(self.live)["format"])
            ex.start("cn", into, "qcow2", ro=False)
            print("carrying %d change(s) into the fresh layer ..." % len(chosen), flush=True)
            ex.call({"op": "carry_into", "drives": [ex.drive("cs", system=True), ex.drive("cn", ro=False)],
                     "paths": self.spec["paths"], "items": chosen})
        except BaseException:
            ex.close()
            os.unlink(into)
            raise
        ex.close()
        print("%s: carried %d change(s); the revert puts them in the fresh layer" % (self.dom, len(chosen)))
        return 0


def cmd_revert_carry(cfg, args):
    dom = args.domain
    spec = cfg.get("carry", {}).get(dom)
    if spec is None:
        die("%s has no carryOnRevert paths configured" % dom)
    tdev, _ = system_disk(Disk(dom, {"image": "", "definition": spec["definition"]}))
    if args.disk and args.disk != tdev:
        return 0
    with locked(dom):
        require_off(dom)
        live, target = args.pair or (live_source(dom, tdev), revert_base(dom, tdev)[1])
        if live == target:
            die("%s runs on %s directly, so there is no snapshot layer to carry from" % (dom, live))
        return CarryReview(cfg, dom, spec, live, target).run(args.into)


def follow_grow(cfg, disk, size):
    # The VM must be off to grow the partition with the image, so a running one waits for the next service start.
    if domstate(disk.dom) not in ("shut off", None):
        print("%s: the data disk grows to %s once the VM is off at a later nixvirt service start" % (disk.dom, human(size)))
        return
    try:
        job = ResizeJob("%s data disk" % disk.dom, disk.image, "data", size)
        job.plan(cfg, disk.dom)
        if job.res["layout"] and (job.res["plan"]["problem"] or job.res["plan"]["risks"]):
            raise SystemExit(job.res["plan"]["problem"] or job.res["plan"]["risks"][0])
        job.apply(cfg, disk.dom)
        print("%s: grew the data disk to %s" % (disk.dom, human(size)))
    except SystemExit as e:
        print("%s: could not grow the data disk: %s" % (disk.dom, e), file=sys.stderr)


def cmd_init(cfg, args):
    doms = sorted(cfg["domains"]) if args.all else [args.domain]
    for dom in doms:
        disk = disk_for(cfg, dom)
        parent = os.path.dirname(disk.image)
        if not os.path.isdir(parent):
            print("%s: %s does not exist; data disk not created" % (dom, parent), file=sys.stderr)
            continue
        size = disk_size(disk)
        if size is None:
            print("%s: the system disk image is missing, so the data disk size is unknown; not created" % dom, file=sys.stderr)
            continue
        with locked(dom):
            recover(disk)
            if os.path.exists(disk.image):
                if os.stat(disk.image).st_size < size:
                    follow_grow(cfg, disk, size)
                continue
            fd = os.open(disk.image, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.ftruncate(fd, size)
            os.close(fd)
            os.makedirs(disk.revs, mode=0o700, exist_ok=True)
            reflink(disk.image, disk.rev(0))
            print("%s: created data disk %s (%s, sparse)" % (dom, disk.image, human(size)))


def opened(cfg, args):
    disk = disk_for(cfg, args.domain)
    require_off(disk.dom)
    recover(disk)
    if not os.path.exists(disk.image):
        die("%s does not exist; run: nixvirt-data init %s" % (disk.image, disk.dom))
    return disk


def cmd_review(cfg, args):
    with locked(args.domain):
        return Review(cfg, opened(cfg, args), args).run()


def cmd_show(cfg, args):
    with locked(args.domain):
        return Review(cfg, opened(cfg, args), args).run(interactive=False, show_all=args.all)


def cmd_keep(cfg, args):
    with locked(args.domain):
        disk = opened(cfg, args)
        if not args.yes and not confirm("keep %s's data disk as rev0 without reviewing it?" % disk.dom):
            return ABORTED
        rotate(disk, True)
        print("%s: kept the data disk as rev0 (older revisions shifted, %d kept)" % (disk.dom, disk.spec["keep"]))
    return 0


def do_carry(cfg, disk, refresh=False):
    # Destination order copies a folder before any carried file that lands inside it.
    entries = sorted(guest_config(disk.spec)["carry"].items(), key=lambda kv: kv[1])
    if not entries:
        die("%s has no windows.carry or linux.carry entries" % disk.dom)
    tdev, _ = system_disk(disk)
    live = live_source(disk.dom, tdev)
    ex = Exports(cfg, disk.dom)
    try:
        ex.start("cs", live, image_info(live)["format"])
        ex.start("dw", disk.image, "raw", ro=False)
        print("copying from %s to the data disk ..." % live, flush=True)
        res = ex.call({"op": "carry", "drives": [ex.drive("cs", system=True), ex.drive("dw", ro=False)], "carry": entries,
                       "refresh": refresh, "probes": sorted({src.split("/")[0] for src, _ in entries})})
    finally:
        ex.close()
    if res["formatted"]:
        print("formatted the data disk: GPT with one %s partition labelled %s" % (res["formatted"], "data" if res["formatted"] == "ext4" else "Data"))
    for it in res["items"]:
        if it.get("missing"):
            print("  %s: not on the system disk, skipped" % safe(it["src"]))
            continue
        if it.get("linked"):
            print("  %s: already links to the data disk, skipped" % safe(it["src"]))
            continue
        if it.get("present"):
            print("  %s: already on the data disk, skipped (--refresh copies it again)" % safe(it["src"]))
            continue
        extra = ", %d links" % it["links"] if it["links"] else ""
        print("  %s -> %s  (%s, %d files%s)" % (safe(it["src"]), safe(it["dst"]), human(it["bytes"]), it["files"], extra))
        for w in it["warnings"]:
            print("    warning: " + safe(w))


def do_link(cfg, disk, dry_run=False, force=False):
    guest = guest_config(disk.spec)
    if not guest["carry"]:
        die("%s has no windows.carry or linux.carry entries" % disk.dom)
    tdev, _ = system_disk(disk)
    live = live_source(disk.dom, tdev)
    info = image_info(live)
    if "backing-filename" not in info and not force:
        die("%s is not a snapshot overlay, so link would edit the system disk with no way back; "
            "take a snapshot first or pass --force" % live)
    ex = Exports(cfg, disk.dom)
    try:
        ex.start("cs", live, info["format"], ro=dry_run)
        ex.start("dd", disk.image, "raw")
        res = ex.call({
            "op": "link",
            "drives": [ex.drive("cs", ro=dry_run, system=True), ex.drive("dd")],
            "letter": guest["letter"],
            "mount_point": guest["mountPoint"],
            "carry": sorted(guest["carry"].items()),
            "user_env": guest["userEnv"],
            "dry_run": dry_run,
        })
    finally:
        ex.close()
    print("%s %s:" % (disk.dom, "would change (dry run, nothing written)" if dry_run else "changed"))
    for step in res["steps"]:
        print("  " + safe(step))


def do_unlink(cfg, disk, dry_run=False, copy=True, force=False, only=None):
    guest = guest_config(disk.spec)
    if not guest["carry"]:
        die("%s has no windows.carry or linux.carry entries" % disk.dom)
    tdev, _ = system_disk(disk)
    live = live_source(disk.dom, tdev)
    info = image_info(live)
    if "backing-filename" not in info and not force:
        die("%s is not a snapshot overlay, so unlink would edit the system disk with no way back; "
            "take a snapshot first or pass --force" % live)
    ex = Exports(cfg, disk.dom)
    try:
        ex.start("cs", live, info["format"], ro=dry_run)
        ex.start("dd", disk.image, "raw")
        if copy and not dry_run:
            print("unlinking; copying folders back from the data disk can take a while ...", flush=True)
        res = ex.call({
            "op": "unlink",
            "drives": [ex.drive("cs", ro=dry_run, system=True), ex.drive("dd")],
            "letter": guest["letter"],
            "mount_point": guest["mountPoint"],
            "carry": sorted(guest["carry"].items()),
            "user_env": guest["userEnv"],
            "copy": copy,
            "only": only or [],
            "dry_run": dry_run,
        })
    finally:
        ex.close()
    print("%s %s:" % (disk.dom, "would change (dry run, nothing written)" if dry_run else "changed"))
    for step in res["steps"] or ["nothing links to the data disk"]:
        print("  " + safe(step))
    if not dry_run and res["changed"]:
        print("next: start %s to check it, then nixvirt-snapshot rotate %s keeps this; after that %s can leave the config" % (
            disk.dom, disk.dom, "those entries" if only else "the data disk"))


def cmd_carry(cfg, args):
    with locked(args.domain):
        do_carry(cfg, opened(cfg, args), args.refresh)
    return 0


def cmd_unlink(cfg, args):
    with locked(args.domain):
        do_unlink(cfg, opened(cfg, args), args.dry_run, not args.no_copy, args.force, args.only)
    return 0


def allocated(path):
    return os.stat(path).st_blocks * 512


def cmd_reclaim(cfg, args):
    dom = args.domain
    with locked(dom), locked(dom, "nixvirt-snapshot"):
        require_off(dom)
        spec = cfg["domains"].get(dom)
        data = spec["image"] if spec else None
        disks = domain_disks(dom)
        picked = [d for d in disks if d[0] == args.disk] if args.disk else [d for d in disks if d[1] != data][:1]
        if not picked:
            die("%s has no disk %s" % (dom, args.disk or "to reclaim"))
        tdev, live = picked[0]
        chain = json.loads(run(["qemu-img", "info", "--backing-chain", "--output=json", "-U", live]))
        base, fmt = chain[-1]["filename"], chain[-1]["format"]
        before = allocated(base)
        print("%s %s: trims the free space of every filesystem in %s (%s allocated)" % (dom, tdev, base, human(before)))
        if len(chain) > 1:
            print("  the snapshot layers above it keep their view, because only blocks no file uses in the base are freed")
        if not args.yes and not confirm("reclaim now?"):
            return ABORTED
        safety = base + ".prereclaim"
        reflink(base, safety)
        try:
            ex = Exports(cfg, dom)
            try:
                ex.start("disk", base, fmt, ro=False, discard=True)
                res = ex.call({"op": "trim", "drives": [ex.drive("disk", ro=False, discard=True)]})
            finally:
                ex.close()
            if fmt == "qcow2":
                run(["qemu-img", "check", "-q", base])
        except BaseException:
            print("the reclaim did not finish; restore the untouched image with: mv %s %s" % (safety, base), file=sys.stderr)
            raise
        os.unlink(safety)
    for p in res["parts"]:
        print("  %s (%s): %s" % (p["part"], p["fs"], "trimmed" if not p["error"] else "skipped, " + safe(p["error"])))
    print("%s: %s allocated, was %s" % (base, human(allocated(base)), human(before)))
    backups = os.path.join(os.path.dirname(base), ".backup")
    if os.path.isdir(backups) and any(n.startswith(dom + "-") for n in os.listdir(backups)):
        print("the backups in %s still hold the freed blocks until they are deleted" % backups)
    return 0


def cmd_link(cfg, args):
    with locked(args.domain):
        do_link(cfg, opened(cfg, args), args.dry_run, args.force)
    return 0


def cmd_migrate(cfg, args):
    dom = args.domain
    with locked(dom):
        disk = opened(cfg, args)
        if not guest_config(disk.spec)["carry"]:
            die("%s needs windows.carry or linux.carry for migrate" % dom)
        tdev, _ = system_disk(disk)
        live = live_source(dom, tdev)
        if "backing-filename" not in image_info(live):
            die("%s runs on %s directly, so there is no snapshot to revert to; take one first" % (dom, live))
        snap, base = revert_base(dom, tdev)
        print("backing up %s ..." % dom, flush=True)
        bdir = backup(dom, [live])
        print("backup: %s" % bdir)
        do_carry(cfg, disk)
        Review(cfg, disk, argparse.Namespace(c_pair=[[live, base]], hash_all=False)).run(interactive=False)
        print()
        if not args.yes and not confirm("keep this data disk, revert %s to snapshot %s and link the folders?" % (dom, snap)):
            print("stopped before the revert; the data disk holds the copied folders and %s is unchanged" % dom)
            return ABORTED
        rotate(disk, True)
        print("%s: kept the data disk as rev0" % dom)
    if subprocess.run(["nixvirt-snapshot", "revert", "-y", "--no-data", dom, snap]).returncode != 0:
        die("the revert failed; the data disk is kept, and the backup is in %s" % bdir)
    with locked(dom):
        do_link(cfg, disk)
    print()
    print("next: start %s and check the data disk, the folder links and the environment, then run: nixvirt-snapshot rotate %s" % (dom, dom))
    print("if something is wrong, nixvirt-snapshot revert %s undoes the links; the full backup is in %s" % (dom, bdir))
    return 0


def resize_image(path, fmt, size, shrink):
    if fmt == "raw":
        os.truncate(path, size)
    else:
        run(["qemu-img", "resize", "-q", "-f", fmt] + (["--shrink"] if shrink else []) + [path, str(size)])


class ResizeJob:
    def __init__(self, label, path, kind, size):
        self.label, self.path, self.kind, self.size = label, path, kind, size
        self.info = image_info(path)
        self.res = None

    def plan(self, cfg, dom):
        ex = Exports(cfg, dom)
        try:
            ex.start("disk", self.path, self.info["format"])
            self.res = ex.call({"op": "resize_plan", "drives": [ex.drive("disk")], "kind": self.kind, "bytes": self.size})
        finally:
            ex.close()

    def changes(self):
        if self.res["layout"] is None:
            return self.size != self.info["virtual-size"]
        target = next(p for p in self.res["layout"]["parts"] if p["num"] == self.res["target"])
        return self.size != self.info["virtual-size"] or self.res["plan"]["end"] != target["end"]

    def describe(self):
        lines = ["%s: %s -> %s" % (self.label, human(self.info["virtual-size"]), human(self.size))]
        if self.res["layout"] is None:
            return lines + ["  no partition table yet, so only the image changes"]
        p = self.res["plan"]
        lines.append("  partition %d: %s -> %s (its files need at least %s)" % (
            self.res["target"], human(p["old_bytes"]), human(p["bytes"]), human(p["minimum"])))
        if p["lv"]:
            lines.append("  then its volume %s and the filesystem in it grow into the new space" % p["lv"])
        for m in p["moves"]:
            what = "Windows recovery" if m["type"].upper() == RECOVERY else "Linux swap" if m["type"].upper() == SWAP else "partition"
            lines.append("  partition %d (%s, %s) moves to the new end" % (m["num"], what, human(m["size"] * p["ss"])))
        if p["problem"]:
            lines.append("  !! " + p["problem"])
        lines += ["  !  " + r for r in p["risks"]]
        return lines

    def apply(self, cfg, dom):
        fmt, current = self.info["format"], self.info["virtual-size"]
        if self.res["layout"] is None:
            resize_image(self.path, fmt, self.size, self.size < current)
            return

        def phase(name):
            ex = Exports(cfg, dom)
            try:
                ex.start("disk", self.path, fmt, ro=False)
                ex.call({"op": "resize_apply", "drives": [ex.drive("disk", ro=False)], "phase": name, "kind": self.kind,
                         "plan": self.res["plan"], "layout": self.res["layout"], "target": self.res["target"]})
            finally:
                ex.close()

        if self.size >= current:
            resize_image(self.path, fmt, self.size, False)
            phase("grow")
        else:
            phase("shrink")
            resize_image(self.path, fmt, self.size, True)
            phase("fixgpt")


def cmd_resize(cfg, args):
    dom = args.domain
    with locked(dom), locked(dom, "nixvirt-snapshot"):
        require_off(dom)
        disks = domain_disks(dom)
        spec = cfg["domains"].get(dom)
        data = spec["image"] if spec else None
        picked = [d for d in disks if d[0] == args.disk] if args.disk else [d for d in disks if d[1] != data][:1]
        if not picked:
            die("%s has no disk %s" % (dom, args.disk or "to resize"))
        tdev, path = picked[0]
        is_data = path == data
        info = image_info(path)
        if not is_data and "backing-filename" not in info and not args.force:
            die("%s is not a snapshot overlay, so a resize could not be reverted; take a snapshot first or pass --force" % path)
        size = to_bytes(args.size, info["virtual-size"])
        jobs = [ResizeJob("%s %s (%s)" % (dom, tdev, path), path, "data" if is_data else "system", size)]
        if spec and not is_data and not spec.get("size") and os.path.exists(data):
            jobs.append(ResizeJob("%s data disk, which follows it (%s)" % (dom, data), data, "data", size))
        for job in jobs:
            job.plan(cfg, dom)
            print("\n".join(job.describe()))
        if any(job.res["layout"] and job.res["plan"]["problem"] for job in jobs):
            die("nothing was changed")
        if any(job.res["layout"] and job.res["plan"]["risks"] for job in jobs) and not args.force:
            die("nothing was changed; --force resizes anyway")
        jobs = [job for job in jobs if job.changes()]
        if not jobs:
            print("nothing to change")
            return 0
        if args.dry_run:
            return 0
        if not args.yes and not confirm("resize now?"):
            return ABORTED
        for job in jobs:
            reflink(job.path, job.path + ".preresize")
        try:
            for job in jobs:
                job.apply(cfg, dom)
        except BaseException:
            print("the resize did not finish; the untouched images are kept next to them:", file=sys.stderr)
            for job in jobs:
                print("  restore with: mv %s.preresize %s" % (job.path, job.path), file=sys.stderr)
            raise
        for job in jobs:
            os.unlink(job.path + ".preresize")
    ntfs = any(job.res["layout"] and job.res["plan"]["fs"] == "ntfs" for job in jobs)
    print("done.%s nixvirt-snapshot revert undoes this, rotate keeps it." % (" Windows checks the resized volumes at its next boot;" if ntfs else ""))
    if any(job.res["layout"] and any(m["type"].upper() == RECOVERY for m in job.res["plan"]["moves"]) for job in jobs):
        print("the recovery partition moved; if 'reagentc /info' in Windows then shows it disabled, "
              "run 'reagentc /disable' and 'reagentc /enable' once.")
    return 0


def revisions(disk):
    found = []
    for i in range(disk.spec["keep"]):
        if os.path.exists(disk.rev(i)):
            found.append(("rev%d" % i, disk.rev(i)))
    if os.path.isdir(disk.revs):
        for name in sorted(os.listdir(disk.revs)):
            if re.fullmatch(r"pin-(.+)\.img", name):
                found.append((name[:-4], os.path.join(disk.revs, name)))
    if os.path.exists(disk.discarded):
        found.append(("discarded", disk.discarded))
    return found


def source_for(disk, name):
    for n, path in revisions(disk):
        if n == name or n == "pin-" + name:
            return path
    die("no revision named %s (see: nixvirt-data list %s)" % (name, disk.dom))


def cmd_list(cfg, args):
    disk = disk_for(cfg, args.domain)
    if not os.path.exists(disk.image):
        print("%s: no data disk yet (%s)" % (disk.dom, disk.image))
        return 0
    st = os.stat(disk.image)
    print("%s data disk: %s (%s virtual, %s allocated, state %s)" % (
        disk.dom, disk.image, human(st.st_size), human(st.st_blocks * 512), domstate(disk.dom) or "unknown"))
    if os.path.exists(disk.rev(0)):
        _, written, trimmed = changed_ranges(disk.image, disk.rev(0))
        print("  written since rev0: %s%s" % (human(written), ", trimmed: %s" % human(trimmed) if trimmed else ""))
    for name, path in revisions(disk):
        when = datetime.fromtimestamp(os.stat(path).st_mtime).strftime("%Y-%m-%d %H:%M")
        print("  %-24s %s" % (name, when))
    return 0


def cmd_restore(cfg, args):
    with locked(args.domain):
        disk = opened(cfg, args)
        source = source_for(disk, args.name)
        if not confirm("replace %s's data disk with %s (the current state is kept as 'discarded')?" % (disk.dom, args.name)):
            return ABORTED
        swap = None
        if source == disk.discarded:
            swap = disk.discarded + ".swap"
            reflink(source, swap, keep_times=True)
            source = swap
        replace_image(disk, source)
        if swap:
            os.unlink(swap)
        print("%s: the data disk was restored from %s" % (disk.dom, args.name))
    return 0


def cmd_pin(cfg, args):
    disk = disk_for(cfg, args.domain)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.pin):
        die("pin names may only use letters, digits, '.', '_' and '-'")
    with locked(disk.dom):
        source = source_for(disk, args.revision)
        if os.path.exists(disk.pin(args.pin)):
            die("pin %s already exists" % args.pin)
        reflink(source, disk.pin(args.pin), keep_times=True)
    print("%s: pinned %s as pin-%s (never expires)" % (disk.dom, args.revision, args.pin))
    return 0


def cmd_unpin(cfg, args):
    disk = disk_for(cfg, args.domain)
    with locked(disk.dom):
        if not os.path.exists(disk.pin(args.pin)):
            die("no pin named " + args.pin)
        if not confirm("delete pin %s?" % args.pin):
            return ABORTED
        os.unlink(disk.pin(args.pin))
    print("%s: removed pin-%s" % (disk.dom, args.pin))
    return 0


def main():
    if len(sys.argv) > 2 and sys.argv[2] == "_worker":
        worker()
        return 0
    cfg = load_config()
    ap = argparse.ArgumentParser(prog="nixvirt-data", description="Persistent data disks with reviewed revisions, carry on revert, "
                                 "and offline disk resizing and trimming.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def command(name, help_text, *args):
        p = sub.add_parser(name, help=help_text)
        for a in args:
            p.add_argument(a)
        return p

    p = command("init", "create configured data disks that do not exist yet")
    p.add_argument("domain", nargs="?")
    p.add_argument("--all", action="store_true")
    for name, help_text in (
        ("review", "review data disk changes since the last kept revision, then keep or discard them"),
        ("show", "print the review summary without changing anything"),
    ):
        p = command(name, help_text, "domain")
        p.add_argument("--c-pair", nargs=2, action="append", metavar=("LIVE", "TARGET"),
                       help="system disk image now and at the revert target, to list files the revert would lose")
        p.add_argument("--hash-all", action="store_true", help="compare every file by content")
        if name == "show":
            p.add_argument("--all", action="store_true", help="also list every change and the diffs")
    command("keep", "keep the data disk as rev0 without a review", "domain").add_argument("-y", "--yes", action="store_true")
    command("migrate", "back up, carry, keep the data disk, revert the system disk and link, in one go",
            "domain").add_argument("-y", "--yes", action="store_true")
    p = command("resize", "grow or shrink a disk offline, moving partitions behind it and resizing its filesystem", "domain", "size")
    p.add_argument("--disk", help="target name such as sda (default: the system disk; its data disk follows it)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("-y", "--yes", action="store_true")
    p.add_argument("--force", action="store_true", help="also resize a disk with no snapshot layer, a volume Windows has not "
                   "checked since its last resize, or down to little free space; never below what the files need")
    command("carry", "copy the windows.carry or linux.carry folders that are not on the data disk yet, formatting it if empty",
            "domain").add_argument("--refresh", action="store_true", help="copy folders already on the data disk again")
    p = command("link", "replace the carried folders on the system disk with junctions, set the drive letter and environment", "domain")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--force", action="store_true", help="allow editing a system disk that is not a snapshot overlay")
    p = command("unlink", "undo link: copy the carried folders back over their junctions, free the drive letter, "
                "remove the environment", "domain")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-copy", action="store_true", help="only remove the links, copying nothing back")
    p.add_argument("--only", action="append", metavar="PATH",
                   help="move back just this system disk path, like Users/me/.vscode, and any environment value pointing into "
                   "its folder, leaving the drive letter and the other links alone. Repeatable, and it works after the entry "
                   "left the config")
    p.add_argument("--force", action="store_true", help="allow editing a system disk that is not a snapshot overlay")
    p = command("reclaim", "return the free space of a disk's base image to the host, for example after link and rotate", "domain")
    p.add_argument("--disk", help="target name such as sda (default: the system disk)")
    p.add_argument("-y", "--yes", action="store_true")
    p = command("revert-carry", "review what changed in the carryOnRevert folders and copy it into the layer a revert creates; "
                "without --into it only shows the changes", "domain")
    p.add_argument("--pair", nargs=2, metavar=("LIVE", "TARGET"),
                   help="system disk image now and at the revert target (default: the current snapshot)")
    p.add_argument("--into", help="overlay to create on TARGET holding the carried changes (nixvirt-snapshot revert passes it)")
    p.add_argument("--disk", help="do nothing unless this target name is the system disk")
    command("list", "show the data disk and its revisions", "domain")
    command("restore", "replace the data disk with a revision, pin or the last discarded state", "domain", "name")
    command("pin", "keep a revision forever under a name", "domain", "revision", "pin")
    command("unpin", "delete a pinned revision", "domain", "pin")
    command("has", "exit 0 if the domain has a data disk", "domain")
    command("has-carry", "exit 0 if the domain has carryOnRevert paths", "domain")
    args = ap.parse_args(sys.argv[2:])
    if args.cmd == "has":
        return 0 if args.domain in cfg["domains"] else 1
    if args.cmd == "has-carry":
        return 0 if args.domain in cfg.get("carry", {}) else 1
    if args.cmd == "init" and not args.all and not args.domain:
        ap.error("init needs a domain or --all")
    return {
        "init": cmd_init, "review": cmd_review, "show": cmd_show, "keep": cmd_keep, "carry": cmd_carry,
        "link": cmd_link, "unlink": cmd_unlink, "migrate": cmd_migrate, "resize": cmd_resize, "reclaim": cmd_reclaim,
        "revert-carry": cmd_revert_carry, "list": cmd_list, "restore": cmd_restore, "pin": cmd_pin, "unpin": cmd_unpin,
    }[args.cmd](cfg, args) or 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        sys.exit(ABORTED)

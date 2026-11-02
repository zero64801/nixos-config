import importlib.util
import json
import os
import re
import struct
import subprocess
import sys
import uuid

import guestfs

TOOL, HIVE = sys.argv[1], sys.argv[2]
W = os.path.abspath("work")
os.makedirs(W + "/bin")
IMG = W + "/t.data.img"
REVS = W + "/t.data.revs"
CFG = W + "/config.json"
BASE = W + "/c.qcow2"
DEFN = W + "/t.xml"
LBASE = W + "/lx.qcow2"
LIMG = W + "/lx.data.img"
LDEFN = W + "/lx.xml"
CDROM = "\\??\\SCSI#CdRom&Ven_QEMU&Prod_QEMU_DVD-ROM#4&1&0&000100#{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}".encode("utf-16-le")
RECOVERY = "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC"
TEMP = "%USERPROFILE%\\AppData\\Local\\Temp\0".encode("utf-16-le")

# Each domain d reads its live system disk, data disk, definition, snapshot base and state from $W/d.*.
with open(W + "/bin/virsh", "w") as f:
    f.write(
        '#!/bin/sh\n'
        'W=%s\n'
        'd="$2"\n'
        'case "$1" in\n'
        '  domstate) cat "$W/$d.state" 2>/dev/null || echo "shut off" ;;\n'
        '  domblklist) printf " Type Device Target Source\\n------\\n file disk sda %%s\\n file disk sdd %%s\\n" '
        '"$(cat "$W/$d.live")" "$(cat "$W/$d.img" 2>/dev/null)" ;;\n'
        '  dumpxml) cat "$W/$d.xml" ;;\n'
        '  snapshot-list|snapshot-current) echo safe0 ;;\n'
        '  snapshot-dumpxml) echo "<domainsnapshot><name>safe0</name><domain><devices><disk type=\\"file\\" device=\\"disk\\">'
        '<source file=\\"$(cat "$W/$d.base")\\"/><target dev=\\"sda\\"/></disk></devices></domain></domainsnapshot>" ;;\n'
        '  *) exit 1 ;;\n'
        'esac\n' % W)
with open(W + "/bin/nixvirt-snapshot", "w") as f:
    f.write('#!/bin/sh\n[ "$1" = revert ] || exit 1\nrm -f %s/m.qcow2\n'
            'qemu-img create -q -f qcow2 -b %s/c.qcow2 -F qcow2 %s/m.qcow2 && echo %s/m.qcow2 > %s/t.live\n' % (W, W, W, W, W))
for name in ("virsh", "nixvirt-snapshot"):
    os.chmod(W + "/bin/" + name, 0o755)
os.environ["PATH"] = W + "/bin:" + os.environ["PATH"]

with open(DEFN, "w") as f:
    f.write('<domain type="kvm"><name>t</name><devices>'
            '<disk type="file" device="disk"><source file="%s"/><target dev="sda" bus="scsi"/></disk>'
            '<disk type="file" device="disk" snapshot="no"><source file="%s"/><target dev="sdd" bus="scsi"/></disk>'
            '</devices></domain>' % (BASE, IMG))

with open(CFG, "w") as f:
    json.dump({"user": os.environ.get("NIXVIRT_DATA_USER", "nobody"), "appliance": os.environ["LIBGUESTFS_PATH"], "domains": {"t": {
        "image": IMG, "size": None, "keep": 3, "definition": DEFN,
        "hashPaths": ["agent", "Work"], "sourcePaths": ["Work"],
        "highlight": {
            "RUNS CODE": ["agent/settings.json", "agent/.agent.json", "agent/plugins/*"],
            "STEERS THE AGENT": ["agent/rules/*", "agent/notes/*"],
        },
        "rescueRoot": "Users/alice", "rescueExclude": ["AppData", "NTUSER.DAT*", "ntuser.*"],
        "windows": {
            "letter": "D",
            "carry": {
                "Users/alice/Desktop/Kit": "Kit",
                "Users/alice/Desktop/Work": "Work",
                "Users/alice/.agent": "agent",
                "Users/alice/.agent.json": "agent/.agent.json",
            },
            "userEnv": {"alice": {"AGENT_HOME": "D:\\agent"}},
        },
    }, "lx": {
        "image": LIMG, "size": None, "keep": 3, "definition": LDEFN, "hashPaths": [], "sourcePaths": [], "highlight": {},
        "rescueRoot": "home/alice", "rescueExclude": [".cache"],
        "linux": {
            "mountPoint": "/mnt/data",
            "carry": {"home/alice/kit": "kit", "home/alice/.agent": "agent", "home/alice/.agent.json": "agent/.agent.json"},
            "userEnv": {"alice": {"AGENT_HOME": "/mnt/data/agent"}},
        },
    }}, "carry": {"t": {
        "paths": ["Users/alice/Documents/notes", "Users/alice/.gitconfig", "Users/alice/AppData/Roaming/App"],
        "hashPaths": [], "sourcePaths": [],
        "highlight": {"STEERS GIT": ["users/alice/.gitconfig"]}, "definition": DEFN,
    }, "lx": {"paths": ["home/alice/notes"], "hashPaths": [], "sourcePaths": [], "highlight": {}, "definition": LDEFN}}}, f)


def nv(*args, answers=""):
    p = subprocess.run([sys.executable, TOOL, CFG] + list(args), input=answers, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def check(cond, what, out=""):
    if not cond:
        print(out)
        raise SystemExit("FAIL: " + what)
    print("ok: " + what)


def put(name, value):
    with open(W + "/" + name, "w") as f:
        f.write(value)


def live(path, dom="t"):
    put(dom + ".live", path)


put("t.img", IMG)
put("t.base", BASE)


def guest(img, fn, ro=False):
    g = guestfs.GuestFS(python_return_dict=True)
    g.add_drive_opts(img, format="qcow2" if img.endswith(".qcow2") else "raw", readonly=ro)
    g.launch()
    try:
        return fn(g)
    finally:
        g.umount_all()
        g.shutdown()
        g.close()


def setattr_hex(g, path, name, value):
    g.debug("sh", ["setfattr -h -n %s -v 0x%s '/sysroot%s'" % (name, value.hex(), path)])


def junction(target):
    sub = ("\\??\\" + target).encode("utf-16-le")
    prn = target.encode("utf-16-le")
    body = struct.pack("<HHHH", 0, len(sub), len(sub) + 2, len(prn)) + sub + b"\0\0" + prn + b"\0\0"
    return struct.pack("<IHH", 0xA0000003, len(body), 0) + body


def system_base(g):
    g.part_init("/dev/sda", "gpt")
    g.part_add("/dev/sda", "p", 2048, 34815)
    g.part_add("/dev/sda", "p", 34816, 423935)
    g.part_add("/dev/sda", "p", 423936, 522239)
    g.part_set_gpt_type("/dev/sda", 3, RECOVERY)
    g.part_set_gpt_attributes("/dev/sda", 3, 0x8000000000000001 - (1 << 64))
    g.part_set_name("/dev/sda", 3, "Recovery")
    g.mkfs("vfat", "/dev/sda1")
    g.mkfs("ntfs", "/dev/sda2")
    g.mkfs("ntfs", "/dev/sda3")
    g.mount("/dev/sda3", "/")
    g.mkdir_p("/Recovery/WindowsRE")
    g.write("/Recovery/WindowsRE/winre.wim", os.urandom(30 << 20))
    g.umount_all()
    g.mount("/dev/sda2", "/")
    for d in ["/Windows/System32/config", "/Users/alice/Desktop/Kit/Viewer", "/Users/alice/Desktop/Work/parser",
              "/Users/alice/.agent/rules/x", "/Users/alice/Downloads", "/Users/alice/AppData/Local",
              "/Users/alice/Documents/notes", "/Users/alice/AppData/Roaming/App"]:
        g.mkdir_p(d)
    g.write("/Users/alice/Documents/notes/a.txt", b"old a\n")
    g.write("/Users/alice/Documents/notes/gone.txt", b"bye\n")
    g.write("/Users/alice/.gitconfig", b"[user]\n")
    g.write("/Users/alice/AppData/Roaming/App/keep.bin", b"K" * 4096)
    g.upload(HIVE, "/Windows/System32/config/SYSTEM")
    g.upload(HIVE, "/Users/alice/NTUSER.DAT")
    g.hivex_open("/Windows/System32/config/SYSTEM", write=True)
    md = g.hivex_node_add_child(g.hivex_root(), "MountedDevices")
    g.hivex_node_set_value(md, "\\DosDevices\\C:", 3, b"DMIO:ID:" + uuid.uuid4().bytes_le)
    g.hivex_node_set_value(md, "\\DosDevices\\D:", 3, CDROM)
    g.hivex_commit(None)
    g.hivex_close()
    g.hivex_open("/Users/alice/NTUSER.DAT", write=True)
    env = g.hivex_node_add_child(g.hivex_root(), "Environment")
    g.hivex_node_set_value(env, "TEMP", 2, TEMP)
    g.hivex_commit(None)
    g.hivex_close()
    g.write("/Users/alice/Desktop/Kit/Viewer/viewer.exe", b"MZ old")
    g.write("/Users/alice/.agent.json", b'{"old": true}\n')


def system_session(g):
    g.mount("/dev/sda2", "/")
    g.write("/Users/alice/Desktop/Kit/Viewer/viewer.exe", b"MZ" + b"A" * 5000)
    g.write("/Users/alice/Desktop/Kit/Viewer/a.dll", b"MZ" + b"B" * 3000)
    g.write("/Users/alice/Desktop/Kit/hidden.txt", b"h")
    setattr_hex(g, "/Users/alice/Desktop/Kit/hidden.txt", "system.ntfs_attrib", bytes.fromhex("22000000"))
    acl = g.lgetxattr("/Users/alice/Desktop/Kit/Viewer", "system.ntfs_acl")
    setattr_hex(g, "/Users/alice/Desktop/Kit/Viewer/a.dll", "system.ntfs_acl", acl)
    g.mkdir("/Users/alice/Desktop/Kit/win")
    setattr_hex(g, "/Users/alice/Desktop/Kit/win", "system.ntfs_reparse_data", junction("C:\\Windows"))
    g.write("/Users/alice/Desktop/Work/parser/main.py", b"print(1)\n")
    g.write("/Users/alice/.agent/settings.json", b'{"hooks": {}}\n')
    g.write("/Users/alice/.agent/rules/x/RULE.md", b"# skill\n")
    g.write("/Users/alice/.agent.json", b'{"new": true}\n')
    g.write("/Users/alice/Downloads/notes.txt", b"important")
    g.write("/Users/alice/AppData/Local/junk.tmp", b"junk")
    n = "/Users/alice/Documents/notes/"
    g.write(n + "a.txt", b"new a, longer\n")
    setattr_hex(g, n + "a.txt", "system.ntfs_acl", acl)
    g.rm(n + "gone.txt")
    g.mkdir_p(n + "new")
    g.write(n + "new/deep.txt", b"deep\n")
    g.write(n + "run.ps1", b"Write-Host hi\n")
    g.mkdir(n + "lnk")
    setattr_hex(g, n + "lnk", "system.ntfs_reparse_data", junction("C:\\Windows"))
    g.write("/Users/alice/.gitconfig", b"[user]\n  name = alice\n")
    st = g.lstatns("/Users/alice/AppData/Roaming/App/keep.bin")
    g.write("/Users/alice/AppData/Roaming/App/keep.bin", b"Q" * 4096)
    g.utimens("/Users/alice/AppData/Roaming/App/keep.bin", st["st_atime_sec"], st["st_atime_nsec"], st["st_mtime_sec"], st["st_mtime_nsec"])


def data_session(g):
    g.mount("/dev/sda1", "/")
    st = g.lstatns("/Kit/Viewer/a.dll")
    g.write("/Kit/Viewer/a.dll", b"MZ" + b"C" * 3000)
    g.utimens("/Kit/Viewer/a.dll", st["st_atime_sec"], st["st_atime_nsec"], st["st_mtime_sec"], st["st_mtime_nsec"])
    g.write("/Kit/Viewer/new.dll", b"MZ")
    g.mkdir_p("/Extra/New")
    g.write("/Extra/New/run.exe", b"MZ")
    g.rm("/Work/parser/main.py")
    g.write("/Work/parser/util.py", b"x = 1\n")
    g.write("/agent/settings.json", b'{"hooks": {"PreToolUse": "evil \x1b[31m"}}\n')
    g.write("/agent/rules/x/RULE.md", b"# skill\nnew instruction\n")
    g.write("/Kit/evil\u202egnp.exe", b"MZ")


def mounted(img, part, fn):
    def inner(g):
        g.mount_ro(part, "/")
        return fn(g)
    return guest(img, inner, ro=True)


def files(img):
    return mounted(img, "/dev/sda1", lambda g: {"/" + p for p in g.find("/")})


def registry(img):
    def read(g):
        out = {}
        for hive, key in (("/Windows/System32/config/SYSTEM", "MountedDevices"), ("/Users/alice/NTUSER.DAT", "Environment")):
            g.hivex_open(hive, write=False)
            node = g.hivex_node_get_child(g.hivex_root(), key)
            if node:
                for v in g.hivex_node_values(node):
                    out[g.hivex_value_key(v["hivex_value_h"])] = g.hivex_value_value(v["hivex_value_h"])
            g.hivex_close()
        return out
    return mounted(img, "/dev/sda2", read)


subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", BASE, "256M"], check=True)
guest(BASE, system_base)
subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-b", BASE, "-F", "qcow2", W + "/s.qcow2"], check=True)
guest(W + "/s.qcow2", system_session)
live(W + "/s.qcow2")

rc, out = nv("init", "t")
check(rc == 0 and os.stat(IMG).st_size == 256 << 20 and os.path.exists(REVS + "/rev0.img"), "init sizes the data disk after the system disk", out)
rc, out = nv("link", "t")
check(rc == 1 and "run carry first" in out, "link refuses before carry", out)

rc, out = nv("carry", "t")
check(rc == 0 and "formatted the data disk" in out, "carry formats the empty data disk", out)
got = files(IMG)
check({"/Kit/Viewer/viewer.exe", "/Work/parser/main.py", "/agent/settings.json", "/agent/.agent.json"} <= got, "carry copies every entry", str(sorted(got)))
rc, out = nv("carry", "t")
check(rc == 0 and out.count("already on the data disk, skipped") == 4 and files(IMG) == got, "a second carry skips what the data disk already holds", out)


def meta(g):
    disk = (g.vfs_label("/dev/sda1"), g.part_get_gpt_type("/dev/sda", 1), g.part_get_gpt_guid("/dev/sda", 1))
    g.mount_ro("/dev/sda1", "/")
    return (g.lgetxattr("/Kit/win", "system.ntfs_reparse_data"), g.lgetxattr("/Kit/hidden.txt", "system.ntfs_attrib"),
            g.lgetxattr("/Kit/Viewer/a.dll", "system.ntfs_acl"), g.read_file("/agent/.agent.json")) + disk


rp, attrib, acl, cjson, label, ptype, guid = guest(IMG, meta, ro=True)
src_acl = mounted(W + "/s.qcow2", "/dev/sda2", lambda g: g.lgetxattr("/Users/alice/Desktop/Kit/Viewer/a.dll", "system.ntfs_acl"))
check(rp == junction("C:\\Windows"), "junctions inside carried folders keep their target", repr(rp))
check(attrib[:1] == b"\x22" and acl == src_acl, "attributes and security descriptors are copied", repr((attrib, acl, src_acl)))
check(cjson == b'{"new": true}\n' and label == "Data" and ptype == "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7",
      "the session's files land on a basic data partition labelled Data", repr((cjson, label, ptype)))

pair = ["--c-pair", W + "/s.qcow2", BASE]
rc, out = nv("show", "t", *pair)
check(rc == 0 and "RUNS CODE" in out and "LEFT ON THE SYSTEM DISK" in out, "show prints the review", out)
check("notes.txt" in out and "junk.tmp" not in out and "NTUSER" not in out and "Desktop/Kit" not in out.split("LEFT ON THE SYSTEM DISK")[1], "show lists only what the revert would really lose", out)
check("Documents/notes" not in out.split("LEFT ON THE SYSTEM DISK")[1] and ".gitconfig" not in out.split("LEFT ON THE SYSTEM DISK")[1],
      "carryOnRevert paths are not offered for rescue", out)
rc, out = nv("keep", "t", "-y")
check(rc == 0 and os.path.exists(REVS + "/rev1.img"), "keep -y rotates without a review", out)

subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-b", BASE, "-F", "qcow2", W + "/r.qcow2"], check=True)
live(W + "/r.qcow2")
rc, out = nv("link", "t", "--dry-run")
check(rc == 0 and "link Users/alice/Desktop/Kit -> D:\\Kit" in out and "move D: (" in out, "link --dry-run prints the plan", out)
check("\\DosDevices\\D:" in registry(W + "/r.qcow2") and registry(W + "/r.qcow2")["\\DosDevices\\D:"] == CDROM, "the dry run writes nothing", out)
rc, out = nv("link", "t")
check(rc == 0, "link applies", out)


def system_after(g):
    g.mount_ro("/dev/sda2", "/")
    return {p: g.lgetxattr("/Users/alice/" + p, "system.ntfs_reparse_data") for p in ("Desktop/Kit", "Desktop/Work", ".agent")}, \
        g.exists("/Users/alice/.agent.json")


links, json_left = guest(W + "/r.qcow2", system_after, ro=True)
check(links == {"Desktop/Kit": junction("D:\\Kit"), "Desktop/Work": junction("D:\\Work"), ".agent": junction("D:\\agent")},
      "carried folders become junctions to the data disk", repr(links))
check(not json_left, "carried files are removed from the system disk", out)
reg = registry(W + "/r.qcow2")
check(reg["\\DosDevices\\D:"] == b"DMIO:ID:" + uuid.UUID(guid).bytes_le and reg["\\DosDevices\\Z:"] == CDROM,
      "drive D: points at the data partition and the CD drive moves to Z:", repr(reg))
check(reg["AGENT_HOME"] == "D:\\agent\0".encode("utf-16-le"), "the user environment variable is set", repr(reg))
rc, out = nv("link", "t")
check(rc == 0 and "already links" in out and "already points" in out and "already D:" in out, "link is idempotent", out)

rc, out = nv("unlink", "t", "--dry-run")
check(rc == 0 and "copy D:\\Kit back to Users/alice/Desktop/Kit" in out and "remove the link Users/alice/Desktop/Kit -> D:\\Kit" in out
      and "copy D:\\agent\\.agent.json back to Users/alice/.agent.json" in out and "free drive D:" in out
      and "alice: remove AGENT_HOME" in out, "unlink --dry-run prints the plan", out)
check(guest(W + "/r.qcow2", system_after, ro=True)[0] == links, "the unlink dry run writes nothing", out)
rc, out = nv("unlink", "t")
check(rc == 0 and "rotate t keeps this" in out, "unlink applies", out)


def system_unlinked(g):
    g.mount_ro("/dev/sda2", "/")
    u = "/Users/alice/"
    return {
        "links": [p for p in ("Desktop/Kit", "Desktop/Work", ".agent") if g.is_symlink(u + p)],
        "ida": g.read_file(u + "Desktop/Kit/Viewer/viewer.exe"),
        "inner": g.lgetxattr(u + "Desktop/Kit/win", "system.ntfs_reparse_data"),
        "acl": g.lgetxattr(u + "Desktop/Kit/Viewer/a.dll", "system.ntfs_acl"),
        "json": g.read_file(u + ".agent.json"),
        "nested": g.exists(u + ".agent/.agent.json"),
        "skill": g.exists(u + ".agent/rules/x/RULE.md"),
        "temp": [p for p in g.find(u) if "nixvirt-unlink" in p],
    }


got = guest(W + "/r.qcow2", system_unlinked, ro=True)
check(got["links"] == [] and got["ida"] == b"MZ" + b"A" * 5000 and got["skill"] and not got["temp"],
      "unlink puts the data disk's folders back in place of the junctions", repr(got))
check(got["inner"] == junction("C:\\Windows") and got["acl"] == src_acl, "junctions and security descriptors inside them come back", repr(got))
check(got["json"] == b'{"new": true}\n' and not got["nested"], "a carried file returns to its own place, not into the carried folder", repr(got))
reg = registry(W + "/r.qcow2")
check("\\DosDevices\\D:" not in reg and reg["\\DosDevices\\Z:"] == CDROM and "\\DosDevices\\C:" in reg,
      "unlink frees the data disk's drive letter and keeps the other mappings", repr(reg))
check("AGENT_HOME" not in reg and reg["TEMP"] == TEMP, "unlink removes the environment variable and keeps the others", repr(reg))
rc, out = nv("unlink", "t")
check(rc == 0 and out.count("is already on the system disk") == 4 and "free drive" not in out and "next:" not in out, "unlink is idempotent", out)
rc, out = nv("link", "t")
check(rc == 0 and guest(W + "/r.qcow2", system_after, ro=True)[0] == links, "link works again after unlink", out)

live(BASE)
rc, out = nv("link", "t")
check(rc == 1 and "not a snapshot overlay" in out, "link refuses a system disk without an overlay", out)
live(W + "/r.qcow2")

guest(IMG, data_session)
# A write straight to the disk, around NTFS, leaves the file's MFT record as it was.
with open(IMG, "r+b") as f:
    image = f.read()
    hits = [m.start() for m in re.finditer(re.escape(b"MZ" + b"A" * 5000), image)]
    f.seek(hits[0] + 2000)
    f.write(b"EVIL")
del image
check(len(hits) == 1, "the raw write found viewer.exe's only copy on the data disk", repr(hits))


def tampered(out):
    return sorted(m.group(1) for m in re.finditer(r"^\s+M\s+(\S+)\s+.*same size and date, different content", out, re.M))


rc, out = nv("show", "t")
rc2, out2 = nv("show", "t", "--hash-all")
check(rc == rc2 == 0 and "block check: " in out and tampered(out) == tampered(out2) == ["Kit/Viewer/a.dll", "Kit/Viewer/viewer.exe"],
      "the block check finds exactly the files that hashing every file finds", out + out2)
rc, out = nv("review", "t", *pair, answers="v\na\n")
check(rc == 10 and "aborted" in out, "abort returns 10 and keeps the data disk", out)
check("a.dll" in out.split("SAME SIZE AND DATE, DIFFERENT CONTENT")[1].split("\n\n")[0], "a timestomped DLL is caught through its MFT record", out)
check("viewer.exe" in out.split("SAME SIZE AND DATE, DIFFERENT CONTENT")[1].split("\n\n")[0], "a raw disk write is caught through the file's clusters", out)
check("settings.json" in out.split("RUNS CODE")[1].split("\n\n")[0] and "Extra/" in out and "Kit/win" not in out, "code rules flag, and unchanged junctions do not", out)
check("RULE.md" in out.split("STEERS THE AGENT")[1].split("\n\n")[0], "configured highlight sections list their files", out)
check("util.py" in out.split("CHANGED")[1] if "CHANGED" in out else False, "script edits under sourcePaths are ordinary changes", out)
check("\x1b" not in out and "\\x1b[31m" in out and "\\u202e" in out, "control and bidi characters are escaped", out)

spec = importlib.util.spec_from_file_location("nixvirt_data", TOOL)
nvd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nvd)


def logfile(g):
    ntfs = nvd.Ntfs(g, "/dev/sda1")
    return g.part_list("/dev/sda")[0]["part_start"] + ntfs.data_runs(ntfs.parse(ntfs.record(2)))[0][1] * ntfs.cs


# A restart page with a client still in the log and no clean flag, as a crash leaves it.
page = bytearray(4096)
page[0:4] = b"RSTR"
struct.pack_into("<HHqIIHhh", page, 4, 0x1E, 9, 0, 4096, 4096, 0x40, 1, 1)
struct.pack_into("<qHHHH", page, 0x40, 7, 1, 0xFFFF, 0, 0)
for k in range(1, 9):
    page[0x1E + 2 * k:0x20 + 2 * k] = page[k * 512 - 2:k * 512]
    page[k * 512 - 2:k * 512] = b"\x01\x00"
page[0x1E:0x20] = b"\x01\x00"
off = guest(IMG, logfile, ro=True)
with open(IMG, "r+b") as f:
    f.seek(off)
    saved = f.read(8192)
    f.seek(off)
    f.write(page + page)
rc, out = nv("show", "t")
with open(IMG, "r+b") as f:
    f.seek(off)
    f.write(saved)
check(rc == 0 and "journal was not closed cleanly" in out, "an unreplayed NTFS journal on the data disk is called out", out)

rc, out = nv("review", "t", *pair, answers="p\n1 5\ny\nr\nall\nk\n")
check(rc == 0 and "kept the data disk as rev0" in out, "prune, rescue and keep complete", out)
got = files(IMG)
check("/Extra/New" not in got and not any("evil" in p for p in got), "pruned items are gone", str(sorted(got)))
check(any(p.endswith("/Users/alice/Downloads/notes.txt") and p.startswith("/Rescued/") for p in got), "the rescued file is on the data disk", str(sorted(got)))
check(os.path.exists(REVS + "/rev2.img"), "revisions rotate up to keep", out)

rc, out = nv("review", "t")
check(rc == 0 and "unchanged" in out, "an untouched data disk needs no review", out)
guest(IMG, lambda g: (g.mount("/dev/sda1", "/"), g.write("/Kit/junk.exe", b"MZ")))
rc, out = nv("review", "t", answers="d\ny\n")
check(rc == 0 and "/Kit/junk.exe" not in files(IMG) and os.path.exists(REVS + "/discarded.img"), "discard returns to rev0", out)
rc, out = nv("restore", "t", "discarded", answers="y\n")
check(rc == 0 and "/Kit/junk.exe" in files(IMG), "the discarded state can be restored", out)
rc, out = nv("pin", "t", "rev1", "clean")
check(rc == 0 and os.path.exists(REVS + "/pin-clean.img"), "pin keeps a revision", out)

put("t.state", "running\n")
rc, out = nv("review", "t", answers="k\n")
check(rc == 1 and "must be shut off" in out, "a running domain is refused", out)
os.unlink(W + "/t.state")

os.replace(REVS + "/rev0.img", REVS + "/.rev-new.img")
rc, out = nv("restore", "t", "rev0", answers="y\n")
check(rc == 0 and os.path.exists(REVS + "/rev0.img"), "an interrupted rotation is finished on the next run", out)

rc, out = nv("carry", "t")
check(rc == 0 and "already links to the data disk, skipped" in out and "/Kit/Viewer/viewer.exe" in files(IMG),
      "carry after link skips junctions instead of copying them over the data disk", out)

live(W + "/s.qcow2")
rc, out = nv("migrate", "t", "-y")
backups = os.listdir(W + "/.backup")
check(rc == 0 and len(backups) == 1 and {"c.qcow2", "s.qcow2", "domain.xml", "snapshot-safe0.xml"} <= set(os.listdir(W + "/.backup/" + backups[0])),
      "migrate backs up the system disk chain and the definitions", out)
links, _ = guest(W + "/m.qcow2", system_after, ro=True)
check(links["Desktop/Kit"] == junction("D:\\Kit") and "kept the data disk as rev0" in out and "LEFT ON THE SYSTEM DISK" in out,
      "migrate carries, reviews, keeps, reverts and links", out)


S = W + "/s.qcow2"
NEW = W + "/n.qcow2"
rc, out = nv("revert-carry", "t", "--pair", S, BASE)
check(rc == 0 and "a plain revert loses" in out and "run.ps1" in out.split("RUNS CODE")[1].split("\n\n")[0], "revert-carry previews the changes and flags scripts", out)
check("keep.bin" in out.split("SAME SIZE AND DATE")[1].split("\n\n")[0] and ".gitconfig" in out.split("STEERS GIT")[1].split("\n\n")[0]
      and "1 deleted" in out.split("DELETED")[1], "the block check, highlight sections and deletions apply to carried paths", out)
rc, out = nv("revert-carry", "t", "--pair", S, BASE, "--into", NEW, answers="a\n")
check(rc == 10 and not os.path.exists(NEW), "aborting the carry review creates nothing", out)
rc, out = nv("revert-carry", "t", "--pair", S, BASE, "--into", NEW, answers="n\n")
check(rc == 0 and not os.path.exists(NEW), "carrying nothing leaves a plain revert", out)
rc, out = nv("revert-carry", "t", "--pair", S, BASE, "--into", NEW, answers="l\n7\nc\n")
check(rc == 0 and re.search(r"^\s*7\s+N\s+Users/alice/Documents/notes/run\.ps1", out, re.M) and "LEFT OUT" in out and "carried 6 change(s)" in out,
      "a left out change is listed apart and the rest is carried", out)


def carried(g):
    g.mount_ro("/dev/sda2", "/")
    n = "/Users/alice/Documents/notes/"
    return {
        "a": g.read_file(n + "a.txt"), "gone": g.exists(n + "gone.txt"), "deep": g.read_file(n + "new/deep.txt"),
        "run": g.exists(n + "run.ps1"), "lnk": g.lgetxattr(n + "lnk", "system.ntfs_reparse_data"),
        "git": g.read_file("/Users/alice/.gitconfig"), "keep": g.read_file("/Users/alice/AppData/Roaming/App/keep.bin"),
        "acl": g.lgetxattr(n + "a.txt", "system.ntfs_acl"), "other": g.exists("/Users/alice/Downloads/notes.txt"),
    }


got = guest(NEW, carried, ro=True)
check(got["a"] == b"new a, longer\n" and not got["gone"] and got["deep"] == b"deep\n" and got["git"] == b"[user]\n  name = alice\n"
      and got["keep"] == b"Q" * 4096, "the chosen changes land in the fresh layer, deletions included", repr(got))
check(not got["run"] and not got["other"], "left out changes and everything outside the carried paths revert", repr(got))
check(got["lnk"] == junction("C:\\Windows") and got["acl"] == mounted(S, "/dev/sda2", lambda g: g.lgetxattr("/Users/alice/Documents/notes/a.txt", "system.ntfs_acl")),
      "junctions and permissions are carried", repr(got))
check(json.loads(subprocess.run(["qemu-img", "info", "--output=json", NEW], capture_output=True, text=True).stdout)["backing-filename"] == BASE,
      "the fresh layer sits on the revert target", NEW)


def vsize(path):
    return json.loads(subprocess.run(["qemu-img", "info", "--output=json", "-U", path], capture_output=True, text=True).stdout)["virtual-size"]


def layout(img, data=False):
    def read(g):
        parts = {p["part_num"]: (p["part_start"] >> 9, p["part_end"] >> 9) for p in g.part_list("/dev/sda")}
        info = {n: (g.part_get_gpt_type("/dev/sda", n), g.part_get_gpt_guid("/dev/sda", n), g.part_get_gpt_attributes("/dev/sda", n),
                    g.part_get_name("/dev/sda", n)) for n in parts}
        root = "/dev/sda1" if data else "/dev/sda2"
        g.mount_ro(root, "/")
        seen = g.find("/")
        size = g.statvfs("/")
        g.umount_all()
        rec = None if data else g.checksum_device("sha256", "/dev/sda3")
        verify = g.debug("sh", ["sgdisk -v /dev/sda 2>&1"])
        return parts, info, len(seen), size["blocks"] * size["frsize"], rec, verify
    return guest(img, read, ro=True)


live(W + "/r.qcow2")
before_c = layout(W + "/r.qcow2")
before_d = layout(IMG, data=True)
rc, out = nv("resize", "t", "+96M", "--dry-run")
check(rc == 0 and "Windows recovery" in out and "moves to the new end" in out and "data disk, which follows it" in out
      and vsize(W + "/r.qcow2") == 256 << 20, "resize --dry-run prints the plan and changes nothing", out)


def windows_boot():
    # Windows clears the check flag ntfsresize sets when it boots, and the test stands in for that boot.
    for img, part in ((W + "/r.qcow2", "/dev/sda2"), (IMG, "/dev/sda1")):
        guest(img, lambda g: g.debug("sh", ["ntfsfix -d %s" % part]))


for step, total, what in (("+32M", 288, "a grow smaller than the recovery partition moves it up in chunks"),
                          ("+128M", 416, "--force resizes a volume Windows has not checked yet"),
                          ("-224M", 192, "a shrink moves NTFS data down, then the recovery partition, then trims the image")):
    force = []
    if step != "+32M":
        rc, out = nv("resize", "t", step, "-y")
        check(rc == 1 and "has not checked partition" in out and "--force resizes anyway" in out and not os.path.exists(W + "/r.qcow2.preresize"),
              "a second resize before Windows checked the volume is refused before anything changes", out)
        if step == "+128M":
            force = ["--force"]
        else:
            windows_boot()
    rc, out = nv("resize", "t", step, "-y", *force)
    after_c = layout(W + "/r.qcow2")
    after_d = layout(IMG, data=True)
    sectors = (total << 20) >> 9
    check(rc == 0 and vsize(W + "/r.qcow2") == total << 20 and os.stat(IMG).st_size == total << 20, what, out)
    check(after_c[0][3][1] <= sectors - 34 and after_c[0][3][0] - after_c[0][2][1] < 2048 * 2 and after_c[0][1] == before_c[0][1],
          "C: fills up to the recovery partition, which sits at the end of the %s disk" % step, repr(after_c[0]))
    check(after_c[1] == before_c[1] and after_c[4] == before_c[4], "partition types, GUIDs, attributes, names and recovery contents are unchanged", repr((after_c[1], before_c[1])))
    check(after_c[2] == before_c[2] and after_d[2] == before_d[2], "every file on C: and on the data disk is still there", repr((after_c[2], after_d[2])))
    check("No problems found" in after_c[5] and "No problems found" in after_d[5], "both GPTs verify cleanly", after_c[5] + after_d[5])
    check(after_d[0][1][1] >= sectors - 34 - 2048, "the data disk follows C: and its partition fills it", repr(after_d[0]))
    check(not os.path.exists(W + "/r.qcow2.preresize") and not os.path.exists(IMG + ".preresize"), "the safety copies are removed after success", out)
    before_c, before_d = after_c, after_d

windows_boot()
# ESP 16 MiB, recovery 48 MiB and 1 MiB of alignment surround C:, so this leaves C: a few MiB short of its files.
cmin = guest(W + "/r.qcow2", lambda g: g.vfs_minimum_size("/dev/sda2"))
rc, out = nv("resize", "t", "%dM" % ((cmin >> 20) + 63), "-y", "--force")
check(rc == 1 and "its files need at least" in out and vsize(W + "/r.qcow2") == 192 << 20, "a shrink below what the files need is refused even with --force", out)
dmin = guest(IMG, lambda g: g.vfs_minimum_size("/dev/sda1"))
tight = "%dM" % ((dmin >> 20) + 18)
rc, out = nv("resize", "t", tight, "--disk", "sdd", "-y")
check(rc == 1 and "too little for the guest" in out and "--force resizes anyway" in out and os.stat(IMG).st_size == 192 << 20,
      "a shrink that leaves little free space needs --force", out)
rc, out = nv("resize", "t", tight, "--disk", "sdd", "-y", "--force")
check(rc == 0 and os.stat(IMG).st_size == ((dmin >> 20) + 18) << 20 and len(files(IMG)) == before_d[2],
      "--force shrinks into the small margin and keeps every file", out)
live(BASE)
rc, out = nv("resize", "t", "+16M", "-y")
check(rc == 1 and "not a snapshot overlay" in out, "resize refuses a disk without a snapshot layer", out)


def fill_and_free(g):
    g.mount("/dev/sda2", "/")
    g.fill_pattern("reclaim!", 100 << 20, "/big.bin")
    g.sync()
    g.rm("/big.bin")


def sums(g):
    g.mount_ro("/dev/sda2", "/")
    g.checksums_out("sha256", "/", W + "/sums")
    with open(W + "/sums") as f:
        return sorted(f.read().splitlines())


guest(BASE, fill_and_free)
subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-b", BASE, "-F", "qcow2", W + "/o.qcow2"], check=True)
guest(W + "/o.qcow2", lambda g: (g.mount("/dev/sda2", "/"), g.write("/Users/alice/after.txt", b"overlay")))
live(W + "/o.qcow2")
alloc_before, view_before = os.stat(BASE).st_blocks * 512, guest(W + "/o.qcow2", sums, ro=True)
rc, out = nv("reclaim", "t", "-y")
check(rc == 0 and "/dev/sda2 (ntfs): trimmed" in out and os.stat(BASE).st_blocks * 512 < alloc_before - (80 << 20),
      "reclaim returns the base image's free space to the host", out)
check(guest(W + "/o.qcow2", sums, ro=True) == view_before and not os.path.exists(BASE + ".prereclaim"),
      "the snapshot layer above the base still reads every file the same", out)
SWAP = "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"


def linux_root(g, root, fstab):
    g.mount(root, "/")
    for d in ("/etc", "/usr/bin", "/usr/lib", "/home", "/boot", "/var", "/root", "/mnt"):
        g.mkdir_p(d)
    g.ln_s("usr/bin", "/bin")
    g.write("/etc/os-release", b'NAME="Arch Linux"\nID=arch\n')
    g.write("/etc/fstab", ("# static table\n" + "".join(ln + "\n" for ln in fstab)).encode())
    g.write("/etc/passwd", b"root:x:0:0::/root:/bin/bash\nalice:x:1000:1000::/home/alice:/bin/bash\n")


def lx_base(g):
    d = "/dev/sda"
    g.part_init(d, "gpt")
    for start, end in ((2048, 34815), (34816, 239615), (239616, 342015), (342016, 374783)):
        g.part_add(d, "p", start, end)
    g.part_set_gpt_type(d, 4, SWAP)
    g.mkfs("vfat", d + "1")
    g.mkfs("ext4", d + "2")
    g.mkfs("ext4", d + "3")
    g.mkswap(d + "4")
    u = {n: g.vfs_uuid(d + str(n)) for n in (1, 2, 3, 4)}
    linux_root(g, d + "2", ["UUID=%s / ext4 rw 0 1" % u[2], "UUID=%s /home ext4 rw 0 2" % u[3],
                            "UUID=%s /boot vfat rw 0 2" % u[1], "UUID=%s none swap defaults 0 0" % u[4]])
    g.mount(d + "3", "/home")
    h = "/home/alice/"
    for x in ("kit/bin", ".agent", "notes"):
        g.mkdir_p(h + x)
    g.write(h + "kit/bin/run.sh", b"#!/bin/sh\necho hi\n")
    g.chmod(0o755, h + "kit/bin/run.sh")
    g.write(h + "kit/data.bin", b"D" * 8192)
    g.write(h + "kit/readme.txt", b"read me\n")
    g.write(h + ".agent/settings.json", b"{}\n")
    g.write(h + ".agent.json", b'{"lx": 1}\n')
    g.write(h + "notes/a.txt", b"a\n")
    g.debug("sh", ["chown -R 1000:1000 /sysroot/home/alice"])


def lx_session(g):
    g.mount("/dev/sda2", "/")
    g.mount("/dev/sda3", "/home")
    h = "/home/alice/"
    g.write(h + ".agent/settings.json", b'{"hooks": 1}\n')
    g.write(h + "notes/a.txt", b"a, edited\n")
    g.write(h + "notes/b.txt", b"b\n")
    g.mkdir_p(h + "Downloads")
    g.write(h + "Downloads/x.txt", b"keep me\n")
    g.debug("sh", ["chown -R 1000:1000 /sysroot/home/alice"])


LS, LR, LN = W + "/lx-s.qcow2", W + "/lx-r.qcow2", W + "/lx-n.qcow2"
subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", LBASE, "192M"], check=True)
guest(LBASE, lx_base)
for path in (LS, LR):
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-b", LBASE, "-F", "qcow2", path], check=True)
guest(LS, lx_session)
put("lx.img", LIMG)
put("lx.base", LBASE)
put("lx.xml", '<domain type="kvm"><name>lx</name><devices>'
              '<disk type="file" device="disk"><source file="%s"/><target dev="sda" bus="scsi"/></disk>'
              '<disk type="file" device="disk" snapshot="no"><source file="%s"/><target dev="sdd" bus="scsi"/></disk>'
              '</devices></domain>' % (LBASE, LIMG))
fstab0 = guest(LBASE, lambda g: (g.mount_ro("/dev/sda2", "/"), g.read_file("/etc/fstab"))[1], ro=True).decode()
live(LS, "lx")
rc, out = nv("init", "lx")
check(rc == 0 and os.stat(LIMG).st_size == 192 << 20, "a Linux guest's data disk follows its system disk too", out)
rc, out = nv("carry", "lx")
check(rc == 0 and "one ext4 partition labelled data" in out, "carry formats a Linux guest's data disk as ext4", out)


def lx_data(g):
    label, ptype = g.vfs_label("/dev/sda1"), g.part_get_gpt_type("/dev/sda", 1)
    g.mount_ro("/dev/sda1", "/")
    st = g.lstatns("/kit/bin/run.sh")
    return {"label": label, "type": ptype, "run": (st["st_mode"] & 0o7777, st["st_uid"]),
            "json": g.read_file("/agent/.agent.json"), "settings": g.read_file("/agent/settings.json")}


got = guest(LIMG, lx_data, ro=True)
check(got["label"] == "data" and got["type"] == "0FC63DAF-8483-4772-8E79-3D69D8477DE4" and got["run"] == (0o755, 1000)
      and got["json"] == b'{"lx": 1}\n' and got["settings"] == b'{"hooks": 1}\n', "carry keeps owners and modes, through a separate /home", repr(got))
rc, out = nv("keep", "lx", "-y")
check(rc == 0, "the Linux data disk is kept as rev0", out)
live(LR, "lx")
rc, out = nv("link", "lx", "--dry-run")
check(rc == 0 and "link home/alice/kit -> /mnt/data/kit" in out and "delete the old home/alice/.agent.json" in out
      and "mount the data disk at /mnt/data through /etc/fstab" in out and "alice: set AGENT_HOME=/mnt/data/agent" in out,
      "link --dry-run plans symlinks, the fstab line and environment.d", out)
rc, out = nv("link", "lx")
check(rc == 0, "link applies on Linux", out)


def lx_system(g):
    g.mount_ro("/dev/sda2", "/")
    g.mount_ro("/dev/sda3", "/home")
    h = "/home/alice/"
    env = h + ".config/environment.d/60-nixvirt-data.conf"
    run_sh = h + "kit/bin/run.sh"
    real = g.is_file(run_sh, followsymlinks=False)
    return {
        "kit": g.readlink(h + "kit") if g.is_symlink(h + "kit") else None,
        "agent": g.readlink(h + ".agent") if g.is_symlink(h + ".agent") else None,
        "owner": g.lstatns(h + "kit")["st_uid"], "fstab": g.read_file("/etc/fstab").decode(), "mnt": g.is_dir("/mnt/data"),
        "env": g.read_file(env) if g.exists(env) else None, "env_owner": g.lstatns(env)["st_uid"] if g.exists(env) else None,
        "run": (g.read_file(run_sh), g.lstatns(run_sh)["st_mode"] & 0o7777) if real else None,
        "json": g.read_file(h + ".agent.json") if g.exists(h + ".agent.json") else None,
        "nested": g.exists(h + ".agent/.agent.json") if g.is_dir(h + ".agent", followsymlinks=False) else None,
        "temp": [p for p in g.find(h) if "nixvirt-unlink" in p],
    }


data_uuid = guest(LIMG, lambda g: g.vfs_uuid("/dev/sda1"), ro=True)
got = guest(LR, lx_system, ro=True)
check(got["kit"] == "/mnt/data/kit" and got["agent"] == "/mnt/data/agent" and got["owner"] == 1000 and got["json"] is None,
      "carried folders become symlinks owned by the user, and the carried file leaves", repr(got))
check(got["fstab"] == fstab0 + "# nixvirt-data: begin, managed from the host\nUUID=%s /mnt/data ext4 defaults,nofail,x-systemd.device-timeout=10s 0 2\n"
      "# nixvirt-data: end\n" % data_uuid and got["mnt"], "a marked fstab block mounts the data disk and the rest stays", got["fstab"])
check(got["env"] == b"AGENT_HOME=/mnt/data/agent\n" and got["env_owner"] == 1000, "environment.d holds the user's environment", repr(got))
rc, out = nv("link", "lx")
check(rc == 0 and out.count("already links") == 2 and "already mounts" in out and "already set" in out, "link is idempotent on Linux", out)


def lx_tamper(g):
    g.mount("/dev/sda1", "/")
    st = g.lstatns("/kit/data.bin")
    g.write("/kit/data.bin", b"E" * 8192)
    g.utimens("/kit/data.bin", st["st_atime_sec"], st["st_atime_nsec"], st["st_mtime_sec"], st["st_mtime_nsec"])
    g.write("/kit/bin/evil", b"\x7fELF")
    g.chmod(0o755, "/kit/bin/evil")
    g.chmod(0o755, "/kit/readme.txt")


guest(LIMG, lx_tamper)
rc, out = nv("show", "lx")
check(rc == 0 and "kit/data.bin" in out.split("SAME SIZE AND DATE")[1].split("\n\n")[0] and "change time check: 1 file" in out,
      "the change time check catches a file rewritten with its old size and date on ext4", out)
runs = out.split("RUNS CODE")[1].split("\n\n")[0]
check("kit/bin/evil" in runs and "kit/readme.txt" in runs and "permissions 644 -> 755" in runs,
      "an execute bit marks code, and a new execute permission is listed", out)
rc, out = nv("show", "lx", "--c-pair", LS, LBASE)
left = out.split("LEFT ON THE SYSTEM DISK")[1]
check("home/alice/Downloads" in left and "notes" not in left and "kit" not in left and ".agent" not in left,
      "the revert scan reads a Linux session through its fstab and lists only what would be lost", out)

rc, out = nv("unlink", "lx")
check(rc == 0 and "remove the data disk from /etc/fstab" in out and "alice: remove" in out, "unlink applies on Linux", out)
got = guest(LR, lx_system, ro=True)
check(got["kit"] is None and got["run"] == (b"#!/bin/sh\necho hi\n", 0o755) and got["owner"] == 1000 and got["json"] == b'{"lx": 1}\n'
      and got["nested"] is not None and not got["nested"] and not got["temp"], "unlink brings folders and the file back with owners and modes", repr(got))
check(got["fstab"] == fstab0 and got["env"] is None, "unlink removes exactly its fstab block and environment file", repr(got))
rc, out = nv("unlink", "lx")
check(rc == 0 and out.count("is already on the system disk") == 3 and "next:" not in out, "unlink is idempotent on Linux", out)
rc, out = nv("link", "lx")
check(rc == 0 and guest(LR, lx_system, ro=True)["kit"] == "/mnt/data/kit", "link works again after unlink on Linux", out)

rc, out = nv("revert-carry", "lx", "--pair", LS, LBASE, "--into", LN, answers="c\n")
check(rc == 0 and "carried 2 change(s)" in out, "revert-carry works on a Linux guest with a separate /home", out)


def lx_notes(g):
    g.mount_ro("/dev/sda2", "/")
    g.mount_ro("/dev/sda3", "/home")
    return g.read_file("/home/alice/notes/a.txt"), g.lstatns("/home/alice/notes/b.txt")["st_uid"], g.exists("/home/alice/Downloads")


check(guest(LN, lx_notes, ro=True) == (b"a, edited\n", 1000, False), "carried Linux files keep their owner and nothing else carries", out)


def lx_layout(img):
    def read(g):
        parts = {p["part_num"]: (p["part_start"] >> 9, p["part_end"] >> 9) for p in g.part_list("/dev/sda")}
        swap = g.vfs_uuid("/dev/sda4")
        g.mount_ro("/dev/sda2", "/")
        st = g.statvfs("/")
        g.mount_ro("/dev/sda3", "/home")
        return parts, swap, st["blocks"] * st["frsize"], sorted(g.find("/home")), g.debug("sh", ["sgdisk -v /dev/sda 2>&1"])
    return guest(img, read, ro=True)


before = lx_layout(LR)
rc, out = nv("resize", "lx", "+64M", "-y")
after = lx_layout(LR)
check(rc == 0 and "Linux swap" in out and vsize(LR) == 256 << 20 and os.stat(LIMG).st_size == 256 << 20
      and "Windows checks" not in out, "a Linux root grows with its disk, and the data disk follows", out)
check(after[0][4][1] <= (256 << 11) - 34 and after[0][3][0] > before[0][3][0] and after[1] == before[1] and after[3] == before[3]
      and after[2] > before[2] + (50 << 20) and "No problems found" in after[4],
      "/home and swap move to the new end with their contents, and ext4 fills the root partition", repr((before, after)))
rc, out = nv("resize", "lx", "-80M", "-y")
shrunk = lx_layout(LR)
check(rc == 0 and vsize(LR) == 176 << 20 and shrunk[2] < after[2] - (60 << 20) and shrunk[1] == before[1] and shrunk[3] == before[3]
      and "No problems found" in shrunk[4], "an ext4 root shrinks, and /home and swap move down intact", out + repr(shrunk))
exact = (192 << 20) + 7 * 512
rc, out = nv("resize", "lx", str(exact), "-y")
check(rc == 0 and vsize(LR) == exact and os.stat(LIMG).st_size == exact and "No problems found" in lx_layout(LR)[4],
      "a size in whole sectors, like a real drive's exact capacity, is kept to the byte", out)


def fs_image(path, kind):
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", path, "512M"], check=True)

    def build(g):
        d = "/dev/sda"
        g.part_init(d, "gpt")
        g.part_add(d, "p", 2048, 34815)
        g.part_add(d, "p", 34816, 34816 + (400 << 11) - 1)
        g.part_add(d, "p", 34816 + (400 << 11), 34816 + (416 << 11) - 1)
        g.part_set_gpt_type(d, 3, SWAP)
        g.mkfs("vfat", d + "1")
        g.mkswap(d + "3")
        if kind == "lvm":
            g.pvcreate(d + "2")
            g.vgcreate("vg0", [d + "2"])
            g.lvcreate("root", "vg0", 200)
            g.mkfs("ext4", "/dev/vg0/root")
            root, line = "/dev/vg0/root", "/dev/mapper/vg0-root / ext4 rw 0 1"
        else:
            g.mkfs(kind, d + "2")
            root, line = d + "2", "UUID=%s / %s rw 0 1" % (g.vfs_uuid(d + "2"), kind)
        linux_root(g, root, [line])
        g.write("/etc/marker", b"fx\n")
    guest(path, build)


def fs_state(path, lvm):
    def read(g):
        root = "/dev/vg0/root" if lvm else "/dev/sda2"
        g.mount_ro(root, "/")
        st = g.statvfs("/")
        return {"fs": st["blocks"] * st["frsize"], "marker": g.read_file("/etc/marker"), "verify": g.debug("sh", ["sgdisk -v /dev/sda 2>&1"])}
    return guest(path, read, ro=True)


for kind in ("btrfs", "xfs", "lvm"):
    path = W + "/fx-%s.qcow2" % kind
    fs_image(path, kind)
    live(path, "fx")
    before = fs_state(path, kind == "lvm")
    rc, out = nv("resize", "fx", "+128M", "-y", "--force")
    after = fs_state(path, kind == "lvm")
    check(rc == 0 and after["fs"] > before["fs"] + (100 << 20) and after["marker"] == b"fx\n" and "No problems found" in after["verify"],
          "%s: the root filesystem grows with the disk" % kind, out + repr((before, after)))
    rc, out = nv("resize", "fx", "-192M", "-y", "--force")
    if kind == "btrfs":
        shrunk = fs_state(path, False)
        check(rc == 0 and shrunk["fs"] < after["fs"] - (100 << 20) and shrunk["marker"] == b"fx\n" and "No problems found" in shrunk["verify"],
              "btrfs: the root filesystem shrinks with the disk", out + repr(shrunk))
    else:
        check(rc == 1 and "can only grow" in out and vsize(path) == 640 << 20, "%s: a shrink is refused before anything changes" % kind, out)
print("all nixvirt-data tests passed")

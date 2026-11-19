"""Opens one running guest for inspection on behalf of the user who asked.

Runs as root through pkexec, with the caller's end of a unix socket as standard input. The guest's memory goes back over
that socket as a descriptor, together with where QEMU maps it, and for as long as the socket stays open a debug socket
may stand beside it. Nothing about the guest's definition changes, so a guest that is never opened pays nothing.
"""
import argparse
import fcntl
import itertools
import json
import os
import pwd
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile

RUN = "/run/vm-inspect"
PIDS = "/run/libvirt/qemu"
RAM_REGION = re.compile(r"^\s+0{16}-[0-9a-f]{16} \(prio \d+, ram\): (\S+)", re.MULTILINE)
# Where a guest's memory can live with a name QEMU's own descriptors point at. A disk image may match the size by chance.
RAM_FILES = ("/memfd:", "/dev/hugepages", "/dev/shm/")
# The name ends up in a QEMU option string and in file names.
DOMAIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
NOT_SHARED = ("its memory is private to QEMU. Back it with <source type=\"memfd\"/> or give it "
              "<access mode=\"shared\"/> in <memoryBacking>, then start it again")


def fail(message):
    print(f"vm-inspect: {message}", file=sys.stderr)
    sys.exit(1)


class Monitor:
    def __init__(self, virsh, domain):
        self.command = [virsh, "-c", "qemu:///system", "qemu-monitor-command", domain]

    def run(self, *arguments):
        done = subprocess.run([*self.command, *arguments], check=False, capture_output=True, text=True, timeout=30)
        if done.returncode != 0:
            fail(f"the monitor refused: {done.stderr.strip()}")
        return done.stdout

    def qmp(self, command):
        return json.loads(self.run(json.dumps({"execute": command})))["return"]

    def hmp(self, line):
        return self.run("--hmp", line)


def guest_pid(domain):
    try:
        with open(f"{PIDS}/{domain}.pid") as f:
            pid = int(f.read())
    except (OSError, ValueError):
        fail(f"{domain} is not running")
    if not runs_guest(pid, domain):
        fail(f"{domain} is not running")
    return pid


def runs_guest(pid, domain):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            arguments = f.read().split(b"\0")
    except OSError:
        return False
    name = f"guest={domain}".encode()
    return any(a == b"-name" and b.split(b",")[0] == name for a, b in itertools.pairwise(arguments))


def guest_ram(monitor, mtree):
    """Size of the memory object behind the guest's RAM, which has to be one QEMU shares with whoever maps it."""
    region = RAM_REGION.search(mtree[mtree.find("Root memory region: system"):])
    if not region:
        fail("could not find the guest's RAM in QEMU's memory map")
    for device in monitor.qmp("query-memdev"):
        if device.get("id") == region.group(1):
            if not device.get("share"):
                fail(NOT_SHARED)
            return device["size"]
    fail(NOT_SHARED)


def ram_descriptor(pid, size):
    folder = f"/proc/{pid}/fd"
    found = []
    for name in os.listdir(folder):
        path = f"{folder}/{name}"
        try:
            target, st = os.readlink(path), os.stat(path)
        except OSError:
            continue
        if stat.S_ISREG(st.st_mode) and st.st_size == size and target.startswith(RAM_FILES):
            found.append(path)
    if len(found) != 1:
        fail(f"expected one memory file of {size} bytes among QEMU's descriptors, found {len(found)}")
    ram = os.open(found[0], os.O_RDWR | os.O_CLOEXEC)
    # Root can open what QEMU only holds, so the file has to be QEMU's own before it is passed on.
    if os.fstat(ram).st_uid != os.stat(f"/proc/{pid}").st_uid:
        fail("the guest's memory file does not belong to its QEMU")
    return ram


def remove(folder):
    # The folder belongs to the guest's own user, so nothing in it is trusted to be what it was.
    if not shutil.rmtree.avoids_symlink_attacks:
        fail("this Python cannot delete a folder safely")
    shutil.rmtree(folder, ignore_errors=True)


def debug_socket(monitor, setfacl, domain, pid, uid):
    """A folder only QEMU writes to and only the caller reaches, with QEMU's debug stub listening in it."""
    owner = os.stat(f"/proc/{pid}").st_uid
    folder = tempfile.mkdtemp(prefix=f"{domain}.", dir=RUN)
    # By user and not by group: a primary group is often one that every account shares.
    subprocess.run([setfacl, "-m", f"u:{uid}:r-x", folder], check=True)
    # With a default ACL the socket's mode comes from here and not from QEMU's umask.
    subprocess.run([setfacl, "-d", "-m", f"u::rwx,u:{uid}:rw-,g::---,o::---", folder], check=True)
    # Last, since nothing root does afterwards may trust what the folder holds.
    os.chown(folder, owner, -1)
    path = f"{folder}/gdb.sock"
    answer = monitor.hmp(f"gdbserver unix:{path},server=on,wait=off")
    try:
        listening = stat.S_ISSOCK(os.lstat(path).st_mode)
    except OSError:
        listening = False
    if not listening:
        monitor.hmp("gdbserver none")
        remove(folder)
        fail(f"QEMU did not open its debug socket: {answer.strip() or 'no reason given'}")
    return folder, path


def main():
    # The settings come first and from the wrapper, everything after them from the caller.
    parser = argparse.ArgumentParser(prog="vm-inspect-open")
    parser.add_argument("settings")
    parser.add_argument("domain")
    parser.add_argument("--gdb", action="store_true")
    args = parser.parse_args()
    with open(args.settings) as f:
        settings = json.load(f)

    if args.domain not in settings["domains"] or not DOMAIN.fullmatch(args.domain):
        fail(f"{args.domain} is not among the domains that may be inspected")
    try:
        uid = pwd.getpwuid(int(os.environ["PKEXEC_UID"])).pw_uid
    except (KeyError, ValueError):
        fail("this is started by vm-inspect, through pkexec")
    if not stat.S_ISSOCK(os.fstat(0).st_mode):
        fail("this is started by vm-inspect, through pkexec")
    caller = socket.socket(fileno=0)

    os.makedirs(RUN, mode=0o755, exist_ok=True)
    lock = os.open(f"{RUN}/{args.domain}.lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fail(f"{args.domain} is already open for inspection")

    monitor = Monitor(settings["virsh"], args.domain)
    pid = guest_pid(args.domain)
    mtree = monitor.hmp("info mtree -f")
    ram = ram_descriptor(pid, guest_ram(monitor, mtree))
    if not runs_guest(pid, args.domain):
        fail(f"{args.domain} stopped")

    # Left behind by a session that was killed. The lock says none is running.
    monitor.hmp("gdbserver none")
    for name in os.listdir(RUN):
        if re.fullmatch(re.escape(args.domain) + r"\.[a-z0-9_]{8}", name):
            remove(f"{RUN}/{name}")

    # So that a session ended from outside still takes its debug socket along.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda *_: sys.exit(1))
    folder, gdb = debug_socket(monitor, settings["setfacl"], args.domain, pid, uid) if args.gdb else (None, None)
    try:
        socket.send_fds(caller, [b"F"], [ram])
        caller.sendall(json.dumps({"mtree": mtree, "gdb": gdb}).encode() + b"\n")
        while caller.recv(4096):
            pass
    except OSError:
        pass
    finally:
        if folder:
            # The guest may have gone in the meantime, which closes the stub by itself.
            subprocess.run([*monitor.command, "--hmp", "gdbserver none"], check=False, capture_output=True, timeout=30)
            remove(folder)


if __name__ == "__main__":
    main()

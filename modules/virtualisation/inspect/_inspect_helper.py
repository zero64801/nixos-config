"""Opens one running guest for inspection on behalf of the user who asked.

Runs as root through pkexec, with the caller's end of a unix socket as standard input. The guest's memory goes back over
that socket as a descriptor, together with where QEMU maps it, and for as long as the socket stays open a debug socket
may stand beside it. Nothing about the guest's definition changes, so a guest that is never opened pays nothing.

A guest whose screen is drawn by a card passed through to it has no picture QEMU could give. When such a guest shares
frames through Looking Glass, the memory they are in goes back too, read only.

While the session lasts the caller may ask, one line of JSON at a time, for a picture of the guest's screen and, when
the session was opened for it, for keys and pointer events to be sent to the guest and for commands to the agent
that runs in it. Each request is checked here and none of it is passed on as the caller wrote it.

The agent's channel is plugged into the guest for such a session and taken out when it ends, so a guest that is not
being driven has no agent anyone could talk to. What the agent answers is written by the guest: it is handed on as a
descriptor and never read here. A file for the guest arrives as a descriptor too and is fed to the agent from here,
which is many times faster than having it sent in requests.

A large file does not go through the agent at all. For the length of one transfer it is the guest's disk: the file to
push as it is, read only, or an empty one of the right size for the guest to write into. It holds bytes and no file
system, so nothing here has to make sense of what a guest wrote, and QEMU gets the file as a descriptor, which is all
it can then reach.
"""
import argparse
import base64
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
import time
import xml.etree.ElementTree

import libvirt
import libvirt_qemu

RUN = "/run/vm-inspect"
PIDS = "/run/libvirt/qemu"
RAM_REGION = re.compile(r"^\s+0{16}-[0-9a-f]{16} \(prio \d+, ram\): (\S+)", re.MULTILINE)
# Where a guest's memory can live with a name QEMU's own descriptors point at. A disk image may match the size by chance.
RAM_FILES = ("/memfd:", "/dev/hugepages", "/dev/shm/")
# The name ends up in a QEMU option string and in file names.
DOMAIN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# The device Looking Glass shares frames through, when QEMU holds one.
FRAMES = re.compile(r"/dev/kvmfr\d+")
# A request fits one argument of a command, which the kernel caps at 128 KiB.
# A picture and what the agent answers travel as descriptors.
REQUEST = 120 * 1024
PICTURE = 256 * 1024 * 1024
ANSWER = 16 * 1024 * 1024
# A file goes to the agent in pieces of this size.
# With 512 KiB the agent of a Linux guest stopped answering, and larger ones than this gained little: 13 MB a second against 10 with a quarter of it.
PIECE, PUSHED = 128 * 1024, 16 * 1024 * 1024 * 1024
# The name the agent in a guest looks for, and the alias that marks a channel as plugged in by a session.
AGENT, AGENT_ALIAS = "org.qemu.guest_agent.0", "ua-vm-inspect-agent"
AGENT_CHANNEL = (f'<channel type="unix"><source mode="bind"/><target type="virtio" name="{AGENT}"/>'
                 f'<alias name="{AGENT_ALIAS}"/></channel>')
# What a session may ask the agent: to look, to run programs and to read and write files. All of it happens in the guest.
AGENT_COMMANDS = ("guest-ping", "guest-info", "guest-get-osinfo", "guest-get-host-name", "guest-get-users", "guest-get-time",
                  "guest-get-timezone", "guest-get-fsinfo", "guest-exec", "guest-exec-status", "guest-file-open", "guest-file-close",
                  "guest-file-read", "guest-file-write", "guest-file-seek", "guest-file-flush")
ARGUMENT = re.compile(r"[a-z0-9-]{1,32}")
# The disk a transfer goes over: how libvirt and the guest know it, and what it may hold at most.
DISK_ALIAS, DISK_NAME, DISKED = "ua-vm-inspect-data", "vm-inspect-data", 1024 * 1024 * 1024 * 1024
DISK = ('<disk type="file" device="disk"><driver name="qemu" type="raw"/><source file="/{name}" fdgroup="{name}"/>'
        '<target dev="{dev}" bus="{bus}"/><serial>{name}</serial>{readonly}{address}<alias name="{alias}"/></disk>')
EVENTS = 64
QCODE = re.compile(r"[a-z0-9_]{1,24}")
BUTTONS = ("left", "middle", "right", "wheel-up", "wheel-down", "side", "extra", "wheel-left", "wheel-right")
NOT_SHARED = ("its memory is private to QEMU. Back it with <source type=\"memfd\"/> or give it "
              "<access mode=\"shared\"/> in <memoryBacking>, then start it again")


def fail(message):
    print(f"vm-inspect: {message}", file=sys.stderr)
    sys.exit(1)


class Monitor:
    def __init__(self, virsh, domain):
        self.command = [virsh, "-c", "qemu:///system", "qemu-monitor-command", domain]

    def attempt(self, *arguments):
        try:
            done = subprocess.run([*self.command, *arguments], check=False, capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            return False, "the monitor did not answer"
        return done.returncode == 0, (done.stdout if done.returncode == 0 else done.stderr.strip())

    def run(self, *arguments):
        fine, answer = self.attempt(*arguments)
        if not fine:
            fail(f"the monitor refused: {answer}")
        return answer

    def qmp(self, command):
        return json.loads(self.run(json.dumps({"execute": command})))["return"]

    def hmp(self, line):
        return self.run("--hmp", line)


class Agent:
    """The agent in the guest, reached through libvirt, which owns its channel."""

    def __init__(self, virsh, domain):
        self.virsh, self.domain = [virsh, "-c", "qemu:///system"], domain
        self.plugged, self.missing = False, "this session was opened without --control, so nothing can be asked of the guest's agent"
        self.connection = self.guest = None

    def run(self, *arguments, device=None, output=subprocess.PIPE):
        """A virsh call that may take a device description, which goes in as a descriptor and not as a file."""
        passed = []
        if device is not None:
            passed.append(os.memfd_create("vm-inspect-device"))
            os.write(passed[0], device.encode())
            arguments = (*arguments, f"/proc/self/fd/{passed[0]}", "--live")
        try:
            return subprocess.run([*self.virsh, *arguments], check=False, stdout=output, stderr=subprocess.PIPE, text=True,
                                  timeout=45, pass_fds=passed)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(arguments, 1, "", "libvirt did not answer")
        finally:
            for descriptor in passed:
                os.close(descriptor)

    def channel(self):
        """Whose agent channel the running guest has: a session's, its own, or none."""
        try:
            devices = xml.etree.ElementTree.fromstring(self.run("dumpxml", self.domain).stdout).iter("channel")
        except xml.etree.ElementTree.ParseError:
            return None
        for device in devices:
            target, alias = device.find("target"), device.find("alias")
            if target is not None and target.get("name") == AGENT:
                return "session" if alias is not None and alias.get("name") == AGENT_ALIAS else "own"
        return None

    def open(self):
        """Makes sure the guest has an agent channel. One left by a session that was killed is taken over."""
        found = self.channel()
        if found is None:
            done = self.run("attach-device", self.domain, device=AGENT_CHANNEL)
            if done.returncode != 0:
                self.missing = f"the agent's channel could not be plugged into the guest: {done.stderr.strip()}"
                return
        self.plugged = found != "own"
        # One connection for the whole session: a program started for every command would take most of the time.
        try:
            libvirt.registerErrorHandler(lambda *_: None, None)
            self.connection = libvirt.open("qemu:///system")
            self.guest = self.connection.lookupByName(self.domain)
        except libvirt.libvirtError as e:
            self.missing = f"libvirt could not be reached for the agent: {e}"
            return
        self.missing = None

    def command(self, text):
        """What the agent answers to one command, as text that is not looked into, or None and why there is none."""
        try:
            return libvirt_qemu.qemuAgentCommand(self.guest, text, 30, 0), None
        except libvirt.libvirtError as e:
            return None, str(e)

    def close(self):
        """Takes the session's channel out again. By its alias: a description would have to name the socket libvirt gave it."""
        self.undisk()
        if self.plugged:
            done = self.run("detach-device-alias", self.domain, AGENT_ALIAS, "--live")
            if done.returncode != 0 and self.channel() == "session":
                print(f"vm-inspect: the agent's channel is still in the guest: {done.stderr.strip()}", file=sys.stderr)

    def ask(self, execute, wanted):
        """The agent's answer as a descriptor and its size, or None and why there is none."""
        if self.missing:
            return None, self.missing
        if execute not in AGENT_COMMANDS:
            return None, f"{execute} is not among what a session may ask the agent"
        arguments = agent_arguments(wanted)
        if arguments is None:
            return None, "an agent command takes text, whole numbers, yes or no and lists of text, by name"
        command = json.dumps({"execute": execute, "arguments": arguments} if arguments else {"execute": execute})
        if len(command) > REQUEST:
            return None, "too much for one command"
        said, why = self.command(command)
        if said is None or not 0 < len(said.encode()) <= ANSWER:
            return None, why or "the agent gave no answer"
        answer = os.memfd_create("vm-inspect-answer")
        with open(answer, "wb", closefd=False) as f:
            f.write(said.encode())
        os.lseek(answer, 0, os.SEEK_SET)
        return answer, len(said.encode())

    def plugged_in(self, alias):
        try:
            return f"<alias name='{alias}'/>" in self.guest.XMLDesc(0)
        except libvirt.libvirtError:
            return False

    def disk(self, source, write):
        """Makes a file the guest's disk for one transfer. Says why it could not, or None when the disk is there."""
        if self.missing:
            return self.missing
        status = os.fstat(source)
        if not stat.S_ISREG(status.st_mode) or not 0 < status.st_size <= DISKED:
            return "what becomes the guest's disk has to be a plain file that is not empty"
        if write and fcntl.fcntl(source, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDWR:
            return "a disk the guest is to write has to be a file that was opened for writing"
        self.undisk()
        try:
            bus, dev, address = self.place()
            self.guest.FDAssociate(DISK_NAME, [source], 0)
            self.guest.attachDeviceFlags(DISK.format(name=DISK_NAME, alias=DISK_ALIAS, bus=bus, dev=dev, address=address,
                                                     readonly="" if write else "<readonly/>"), libvirt.VIR_DOMAIN_AFFECT_LIVE)
        except (libvirt.libvirtError, xml.etree.ElementTree.ParseError) as e:
            return f"the disk could not be plugged into the guest: {e}"
        return None

    def place(self):
        """Where a disk can join the running guest: the bus, a name no disk has, and its place on the bus.

        A virtio-scsi controller takes one more disk as it is, where anything else on the PCI bus would need a free
        slot for a new device. The place is spelled out, since libvirt would derive one from the name and may then
        want a second controller. A guest without such a controller gets a USB disk.
        """
        devices = xml.etree.ElementTree.fromstring(self.guest.XMLDesc(0)).find("devices")
        taken = {target.get("dev") for target in devices.iter("target")}
        dev = next(f"sd{letter}" for letter in "zyxwvutsrqponmlkjihgfedcb" if f"sd{letter}" not in taken)
        for controller in devices.iter("controller"):
            if controller.get("type") == "scsi" and controller.get("model") == "virtio-scsi":
                index = controller.get("index", "0")
                units = [int(a.get("unit", "0")) for a in devices.iter("address") if a.get("type") == "drive" and a.get("controller") == index]
                return "scsi", dev, f'<address type="drive" controller="{int(index)}" bus="0" target="0" unit="{max(units, default=-1) + 1}"/>'
        return "usb", dev, ""

    def undisk(self):
        """Takes the transfer's disk out of the guest and waits for it to be gone. Says why it is still there, or None."""
        if self.guest is None or not self.plugged_in(DISK_ALIAS):
            return None
        try:
            self.guest.detachDeviceAlias(DISK_ALIAS, libvirt.VIR_DOMAIN_AFFECT_LIVE)
        except libvirt.libvirtError as e:
            return f"the disk could not be taken out of the guest: {e}"
        for _ in range(100):
            if not self.plugged_in(DISK_ALIAS):
                return None
            time.sleep(0.1)
        return "the guest has not let go of the disk"

    def push(self, handle, source):
        """Feeds a file into one the agent holds open in the guest. Says why it stopped, or None when all of it went in."""
        if self.missing:
            return self.missing
        if type(handle) is not int or not 0 <= handle < 2 ** 63:
            return "a push names the handle the agent gave for the file in the guest"
        status = os.fstat(source)
        if not stat.S_ISREG(status.st_mode) or status.st_size > PUSHED:
            return "what is pushed has to be a plain file of at most 16 GiB"
        while True:
            piece = os.read(source, PIECE)
            if not piece:
                return None
            arguments = {"handle": handle, "buf-b64": base64.b64encode(piece).decode()}
            _, why = self.command(json.dumps({"execute": "guest-file-write", "arguments": arguments}))
            if why:
                return why


def agent_arguments(wanted):
    """The arguments of an agent command, rebuilt from the plain values that are allowed. None for anything else."""
    if wanted is None:
        return {}
    if not isinstance(wanted, dict) or len(wanted) > 16:
        return None
    arguments = {}
    for name, value in wanted.items():
        if not isinstance(name, str) or not ARGUMENT.fullmatch(name):
            return None
        if isinstance(value, (bool, str)) or (type(value) is int and -2 ** 63 <= value < 2 ** 64):
            arguments[name] = value
        elif isinstance(value, list) and len(value) <= 256 and all(isinstance(item, str) for item in value):
            arguments[name] = list(value)
        else:
            return None
    return arguments


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


def frames_descriptor(pid):
    """The memory a Looking Glass host in the guest writes frames to, for reading. None for a guest without one."""
    folder = f"/proc/{pid}/fd"
    found = []
    for name in os.listdir(folder):
        path = f"{folder}/{name}"
        try:
            target, st = os.readlink(path), os.stat(path)
        except OSError:
            continue
        if stat.S_ISCHR(st.st_mode) and FRAMES.fullmatch(target):
            found.append((path, st.st_rdev))
    if len({device for _, device in found}) != 1:
        return None
    frames = os.open(found[0][0], os.O_RDONLY | os.O_CLOEXEC)
    st = os.fstat(frames)
    if not stat.S_ISCHR(st.st_mode) or st.st_rdev != found[0][1]:
        os.close(frames)
        return None
    return frames


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


def picture(virsh, domain):
    """The guest's screen as QEMU draws it, in a file only this process and whoever gets the descriptor can reach."""
    shot = os.memfd_create("vm-inspect-shot")
    try:
        done = subprocess.run([virsh, "-c", "qemu:///system", "screenshot", domain, f"/proc/self/fd/{shot}"],
                              check=False, capture_output=True, text=True, timeout=30, pass_fds=[shot])
    except subprocess.TimeoutExpired:
        os.close(shot)
        return None, "the screenshot took too long"
    size = os.fstat(shot).st_size
    if done.returncode != 0 or not 0 < size <= PICTURE:
        os.close(shot)
        # The first is QEMU's answer, the second libvirt's when the domain has no video device at all.
        if "no console" in done.stderr or "no screens" in done.stderr:
            return None, "QEMU draws no screen for this guest, as when its display is a card passed through to it"
        return None, done.stderr.strip() or "QEMU gave no picture"
    return shot, size


def event(wanted):
    """One event in QEMU's words, built from the few fields that are allowed. None for anything else."""
    if not isinstance(wanted, dict):
        return None
    kind, down, value = wanted.get("type"), wanted.get("down"), wanted.get("value")
    if kind == "key" and isinstance(wanted.get("key"), str) and QCODE.fullmatch(wanted["key"]) and isinstance(down, bool):
        return {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": wanted["key"]}}}
    if kind == "btn" and wanted.get("button") in BUTTONS and isinstance(down, bool):
        return {"type": "btn", "data": {"down": down, "button": wanted["button"]}}
    lowest = {"rel": -0x8000, "abs": 0}.get(kind)
    if lowest is not None and wanted.get("axis") in ("x", "y") and type(value) is int and lowest <= value <= 0x7fff:
        return {"type": kind, "data": {"axis": wanted["axis"], "value": value}}
    return None


def answer(request, received, monitor, virsh, domain, control, agent):
    """What goes back for one request: a dictionary, and a descriptor when the answer is a picture or the agent's."""
    try:
        request = json.loads(request)
    except ValueError:
        request = None
    if not isinstance(request, dict):
        return {"error": "a request is one JSON object on a line"}, None
    if request.get("do") == "shot":
        shot, result = picture(virsh, domain)
        return ({"size": result}, shot) if shot is not None else ({"error": result}, None)
    if request.get("do") == "input":
        if not control:
            return {"error": "this session was opened without --control, so nothing can be sent to the guest"}, None
        wanted = request.get("events")
        if not isinstance(wanted, list) or not 0 < len(wanted) <= EVENTS:
            return {"error": f"between 1 and {EVENTS} events at a time"}, None
        events = [event(w) for w in wanted]
        if None in events:
            return {"error": "an event is a key, a btn, a rel or an abs with its own fields"}, None
        fine, said = monitor.attempt(json.dumps({"execute": "input-send-event", "arguments": {"events": events}}))
        return ({} if fine else {"error": said}), None
    if request.get("do") == "agent":
        if not isinstance(request.get("execute"), str):
            return {"error": "an agent request names what to execute"}, None
        descriptor, result = agent.ask(request["execute"], request.get("arguments"))
        return ({"size": result}, descriptor) if descriptor is not None else ({"error": result}, None)
    if request.get("do") == "push":
        if len(received) != 1:
            return {"error": "a push comes with the one file to push"}, None
        why = agent.push(request.get("handle"), received[0])
        return ({"error": why} if why else {}), None
    if request.get("do") == "disk":
        if len(received) != 1:
            return {"error": "a disk comes with the one file it is made of"}, None
        why = agent.disk(received[0], request.get("write") is True)
        return ({"error": why} if why else {}), None
    if request.get("do") == "undisk":
        why = agent.undisk() if not agent.missing else agent.missing
        return ({"error": why} if why else {}), None
    return {"error": "the session takes shot, input, agent, push, disk and undisk"}, None


def serve(caller, monitor, virsh, domain, control, agent):
    """Answers requests until the caller closes its end, which is how a session ends."""
    pending, received = b"", []
    while True:
        while b"\n" not in pending:
            if len(pending) > REQUEST or len(received) > 4:
                return
            more, descriptors, _, _ = socket.recv_fds(caller, 4096, 4)
            received += descriptors
            if not more:
                return
            pending += more
        request, _, pending = pending.partition(b"\n")
        descriptor = None
        try:
            reply, descriptor = answer(request, received, monitor, virsh, domain, control, agent)
            line = json.dumps(reply).encode() + b"\n"
            if descriptor is None:
                caller.sendall(line)
            else:
                socket.send_fds(caller, [line], [descriptor])
        finally:
            for held in [*received, *([] if descriptor is None else [descriptor])]:
                os.close(held)
            received = []


def main():
    # The settings come first and from the wrapper, everything after them from the caller.
    parser = argparse.ArgumentParser(prog="vm-inspect-open")
    parser.add_argument("settings")
    parser.add_argument("domain")
    parser.add_argument("--gdb", action="store_true")
    parser.add_argument("--control", action="store_true")
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
    frames = frames_descriptor(pid)
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
    agent = Agent(settings["virsh"], args.domain)
    try:
        if args.control:
            agent.open()
        socket.send_fds(caller, [b"F"], [ram] if frames is None else [ram, frames])
        caller.sendall(json.dumps({"mtree": mtree, "gdb": gdb}).encode() + b"\n")
        serve(caller, monitor, settings["virsh"], args.domain, args.control, agent)
    except OSError:
        pass
    finally:
        agent.close()
        if folder:
            # The guest may have gone in the meantime, which closes the stub by itself.
            subprocess.run([*monitor.command, "--hmp", "gdbserver none"], check=False, capture_output=True, timeout=30)
            remove(folder)


if __name__ == "__main__":
    main()

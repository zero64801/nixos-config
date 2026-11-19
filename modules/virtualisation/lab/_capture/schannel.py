"""SChannel's TLS secrets, read from outside at the moments lsass works them out.

Windows' own TLS, used by PowerShell, .NET, the system's services and many programs, does its handshakes in lsass.exe
through ncrypt.dll. The secrets never reach the program that asked. The method is the one published by ngo
(win-frida-scripts, "Decrypting Schannel TLS traffic"), after Jacob Kambic's research, and runs here on the CPU's debug
registers through QEMU's stub instead of on hooks in the guest, so lsass is neither changed nor protected against it:

- SslHashHandshake gets each handshake message, and the first, the ClientHello, holds the client random.
- SslGenerateSessionKeys gets the master key of TLS 1.2 and a list of buffers with the client random, for new and
  resumed sessions alike. The key is behind its handle: a structure tagged BDDD, at 0x10 a pointer to one tagged 5lss,
  and 48 bytes at 0x1c of that.
- SslExpandTrafficKeys hands back two keys of TLS 1.3, for the handshake on its first call in a thread and for the
  traffic on its second. Each secret is behind a chain of structures: BDDD, then 0x10, 0x20 and 0x10 further on, its
  size at 0x10 and its address at 0x18 of the last.

The offsets were found on Windows 10 and may move in another release. A tag that is not where it should be is said and
nothing is written for that key.
"""
import importlib.util
import os
import struct
import sys
import time

import capture as shared
from capture import plain

ROOT = 0x000FFFFFFFFFF000
# NCRYPTBUFFER_SSL_CLIENT_RANDOM of ncrypt.h.
CLIENT_RANDOM = 20
FUNCTIONS = ("SslHashHandshake", "SslGenerateSessionKeys", "SslExpandTrafficKeys")
REGISTERS = ["rcx", "rdx", "r8", "r9", "rsp", "rip", "cr3", "gs_base"]


class Unexpected(Exception):
    """Memory did not look as the method expects, with what was found instead."""


class Secrets:
    """What each stop yields, given the registers and a way to read lsass' memory. Holds what spans several stops."""

    def __init__(self):
        self.randoms, self.stages = {}, {}

    @staticmethod
    def pointer(read, address):
        return struct.unpack("<Q", read(address, 8))[0]

    @staticmethod
    def tagged(read, address, tag):
        found = read(address + 4, 4)
        if found not in (tag, tag[::-1]):
            raise Unexpected(f"{tag.decode()} was expected at {address + 4:#x} and {found!r} is there")

    def handshake(self, regs, read):
        """SslHashHandshake(provider, hash, input, length, flags): keeps the client random of a ClientHello for its thread."""
        if regs["r9"] < 38:
            return []
        message = read(regs["r8"], 38)
        if message[0] == 1 and message[4:6] == b"\x03\x03":
            self.randoms[regs["gs_base"]] = message[6:38].hex()
        return []

    def session_keys(self, regs, read):
        """SslGenerateSessionKeys(provider, master key, read key, write key, parameters, flags): the master key of TLS 1.2."""
        handle = regs["rdx"]
        self.tagged(read, handle, b"BDDD")
        inner = self.pointer(read, handle + 0x10)
        self.tagged(read, inner, b"5lss")
        key = read(inner + 0x1C, 48)
        random = self.parameter_random(read, self.pointer(read, regs["rsp"] + 0x28)) or self.randoms.get(regs["gs_base"])
        if not random:
            raise Unexpected("the client random was in neither the parameters nor an earlier ClientHello of this thread")
        return [f"CLIENT_RANDOM {random} {key.hex()}"]

    def parameter_random(self, read, descriptor):
        """The client random among the buffers of an NCryptBufferDesc, or None."""
        if not descriptor:
            return None
        count, = struct.unpack("<I", read(descriptor + 4, 4))
        buffers = self.pointer(read, descriptor + 8)
        for i in range(min(count, 16)):
            size, kind, data = struct.unpack("<IIQ", read(buffers + 16 * i, 16))
            if kind == CLIENT_RANDOM and size == 32:
                return read(data, 32).hex()
        return None

    def expand_entry(self, regs, read):
        """SslExpandTrafficKeys(provider, base key, hash, first key out, second key out, flags): where its keys will be."""
        return {"first": regs["r9"], "second": self.pointer(read, regs["rsp"] + 0x28), "thread": regs["gs_base"],
                "back": self.pointer(read, regs["rsp"]), "rsp": regs["rsp"] + 8}

    def expand_return(self, pending, read):
        """The two secrets SslExpandTrafficKeys handed back, as key log lines."""
        thread = pending["thread"]
        suffix = "TRAFFIC_SECRET_0" if self.stages.get(thread) else "HANDSHAKE_TRAFFIC_SECRET"
        self.stages[thread] = suffix != "TRAFFIC_SECRET_0"
        random = self.randoms.get(thread)
        if not random:
            raise Unexpected("no ClientHello was seen in this thread before its TLS 1.3 keys")
        first, second = (self.secret(read, self.pointer(read, pending[side])) for side in ("first", "second"))
        return [f"CLIENT_{suffix} {random} {first.hex()}", f"SERVER_{suffix} {random} {second.hex()}"]

    def secret(self, read, handle):
        self.tagged(read, handle, b"BDDD")
        held = self.pointer(read, self.pointer(read, self.pointer(read, handle + 0x10) + 0x20) + 0x10)
        size, = struct.unpack("<I", read(held + 0x10, 4))
        if size not in (32, 48):
            raise Unexpected(f"a secret of {size} bytes, where TLS 1.3 has 32 or 48")
        return read(self.pointer(read, held + 0x18), size)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(shared.SETTINGS.dbg, f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(capture, args):
    """Stops lsass at the three functions for as long as asked and adds each secret to the capture."""
    target, device = os.environ.get("VM_INSPECT_GDB"), os.environ.get("VM_INSPECT_DEVICE")
    if not target or not device:
        shared.fail("this needs the session's memory and its debug stub, as vm-lab opens them")
    windows, mi = load("windows"), load("mi")
    try:
        guest = windows.Windows(shared.SETTINGS.vmm, device)
        pid = guest.pid("lsass.exe")
        _, roots = guest.process(pid)
        roots = {root & ROOT for root in roots}
        places = {name: guest.address(pid, "ncrypt.dll", name) for name in FUNCTIONS}
    except LookupError as e:
        shared.fail(f"lsass and its ncrypt.dll were not found in the guest's memory: {e}")
    print(f"guest-net: lsass is process {pid}, " + ", ".join(f"{n} at {a:#x}" for n, a in places.items()), file=sys.stderr)
    gdb = mi.Gdb(shared.SETTINGS.gdb)
    secrets, found, odd, running, pending = Secrets(), 0, set(), False, None
    until = time.monotonic() + args.seconds if args.seconds else None

    def read(address, size):
        values, _ = gdb.run(f"-data-read-memory-bytes {address:#x} {size}")
        data = bytes.fromhex("".join(block["contents"] for block in values["memory"]))
        if len(data) != size:
            raise Unexpected(f"{size} bytes at {address:#x} could not be read")
        return data

    try:
        for setting in ("mi-async on", "pagination off", "confirm off"):
            gdb.run(f"-gdb-set {setting}")
        gdb.run(f"-target-select remote {target}", wait=60)
        gdb.stops.clear()
        names, _ = gdb.run("-data-list-register-names")
        index = {n: i for i, n in enumerate(names["register-names"]) if n}
        if "cr3" not in index:
            shared.fail("this debug stub does not show the page table root, so lsass' stops cannot be told apart")
        numbers = {}
        for name, address in places.items():
            values, _ = gdb.run(f"-break-insert -h *{address:#x}")
            numbers[values["bkpt"]["number"]] = name
        gdb.run("-exec-continue")
        running = True
        print("guest-net: following lsass, Ctrl-C ends it", file=sys.stderr)
        while until is None or time.monotonic() < until:
            stop = gdb.stopped(time.monotonic() + (min(1.0, until - time.monotonic()) if until else 1.0))
            if stop is None:
                continue
            running = False
            values, _ = gdb.run("-data-list-register-values --skip-unavailable x " + " ".join(str(index[n]) for n in REGISTERS if n in index))
            by_number = {int(v["number"]): int(v["value"], 16) for v in values.get("register-values", [])}
            regs = {n: by_number.get(index.get(n, -1), 0) for n in REGISTERS}
            number = stop.get("bkptno")
            lines = []
            if regs["cr3"] & ROOT in roots:
                try:
                    if pending and number == pending["number"]:
                        if regs["rsp"] == pending["rsp"]:
                            lines = secrets.expand_return(pending, read)
                            gdb.run(f"-break-delete {number}")
                            pending = None
                    elif numbers.get(number) == "SslHashHandshake":
                        lines = secrets.handshake(regs, read)
                    elif numbers.get(number) == "SslGenerateSessionKeys":
                        lines = secrets.session_keys(regs, read)
                    elif numbers.get(number) == "SslExpandTrafficKeys" and pending is None:
                        pending = secrets.expand_entry(regs, read)
                        values, _ = gdb.run(f"-break-insert -h *{pending['back']:#x}")
                        pending["number"] = values["bkpt"]["number"]
                except Unexpected as e:
                    if str(e) not in odd:
                        odd.add(str(e))
                        print(f"guest-net: {numbers.get(number, 'a return')}: {plain(e, 300)}", file=sys.stderr)
            if lines:
                shared.tell({"do": "note", "kind": "keys", "lines": lines})
                found += len(lines)
                for line in lines:
                    print(line.split(" ")[0], line.split(" ")[1][:16] + "...")
                sys.stdout.flush()
            gdb.run("-exec-continue")
            running = True
    except KeyboardInterrupt:
        pass
    except mi.Failed as e:
        print(f"guest-net: gdb: {e}", file=sys.stderr)
    finally:
        try:
            if running:
                gdb.run("-exec-interrupt")
                gdb.stopped(time.monotonic() + 15)
            gdb.run("-break-delete")
            gdb.run("-target-detach")
            gdb.run("-gdb-exit", wait=5)
        except mi.Failed:
            pass
        gdb.close()
    print(f"guest-net: {found} secrets added to the capture, and the guest runs on", file=sys.stderr)
    if odd:
        print("guest-net: what lsass held did not look as expected, so this Windows may keep its keys at other offsets", file=sys.stderr)

"""keys scan: the TLS secrets of any program in the guest, found in its memory from outside and checked against the capture.

A program that talks TLS keeps the secrets of each connection in its memory while the connection lasts, since TLS 1.3
needs them to update its keys. This reads that memory without the guest seeing it, tries the windows that could be
secrets against the flow's own encrypted records, and adds to the capture only what opens them. The libraries most
programs use keep the client random beside the secrets, so its places in memory are searched first.

The search runs in libtlsscan, in C on libcrypto, since it tries millions of windows.
"""
import ctypes
import importlib.util
import json
import os
import re
import socket
import sys
import time

import capture as shared
import owners
import packets
import tlsrecords
from capture import first, plain, size, tell

u32, u64 = ctypes.c_uint32, ctypes.c_uint64


class Record(ctypes.Structure):
    _fields_ = [("direction", u32), ("type", u32), ("version", u32), ("length", u32), ("body", ctypes.c_void_p)]


class Target(ctypes.Structure):
    _fields_ = [("version", u32), ("suite", u32), ("etm", u32), ("nrecords", u32), ("records", ctypes.POINTER(Record)),
                ("client_random", ctypes.c_uint8 * 32), ("server_random", ctypes.c_uint8 * 32)]


class Hit(ctypes.Structure):
    _fields_ = [("target", u32), ("record", u32), ("inner", u32), ("first", u32), ("length", u32), ("pad", u32), ("address", u64),
                ("secret", ctypes.c_uint8 * 48)]


def address(buffer):
    """Where a bytes or bytearray's contents are, or the address itself, for the C side, which only reads them."""
    if isinstance(buffer, int):
        return buffer
    if isinstance(buffer, bytes):
        return ctypes.cast(ctypes.c_char_p(buffer), ctypes.c_void_p).value
    return ctypes.addressof(ctypes.c_char.from_buffer(buffer))


class Found:
    """A secret that opened a record of a session: its key log line and where it was."""

    def __init__(self, session, hit):
        direction, _, _, _ = session.records[hit.record]
        index = sum(1 for r in session.records[: hit.record] if r[0] == direction)
        self.session, self.address = session, hit.address
        self.label = tlsrecords.label(session, direction, index, hit.inner, hit.first)
        self.secret = bytes(hit.secret[: hit.length])

    @property
    def line(self):
        return f"{self.label} {self.session.client_random.hex()} {self.secret.hex()}"


class Scanner:
    def __init__(self, library):
        lib = self.lib = ctypes.CDLL(library)
        lib.tlsscan_supported.restype = ctypes.c_int
        lib.tlsscan_supported.argtypes = [u32, u32]
        lib.tlsscan_scan.restype = ctypes.c_size_t
        lib.tlsscan_scan.argtypes = [ctypes.c_void_p, ctypes.c_size_t, u64, ctypes.c_size_t, ctypes.c_uint, ctypes.POINTER(Target),
                                     ctypes.c_size_t, ctypes.POINTER(Hit), ctypes.c_size_t, ctypes.POINTER(u64)]
        lib.tlsscan_find.restype = ctypes.c_size_t
        lib.tlsscan_find.argtypes = [ctypes.c_void_p, ctypes.c_size_t, u64, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint,
                                     ctypes.POINTER(u64), ctypes.POINTER(u32), ctypes.c_size_t]
        self.tested = 0

    def supported(self, session):
        return bool(self.lib.tlsscan_supported(session.version, session.suite))

    def scan(self, buffer, length, base, sessions, step=8, threads=1, at=0):
        """The secrets of the sessions in length bytes of the buffer from at, whose first byte is at address base."""
        if not sessions or length < 32:
            return []
        targets = (Target * len(sessions))()
        kept = []
        for target, session in zip(targets, sessions):
            records = (Record * max(1, len(session.records)))()
            for record, (direction, kind, version, body) in zip(records, session.records):
                record.direction, record.type, record.version, record.length, record.body = direction, kind, version, len(body), address(body)
                kept.append(body)
            kept.append(records)
            target.version, target.suite, target.etm, target.nrecords = session.version, session.suite, int(session.etm), len(session.records)
            target.records = records
            target.client_random[:] = session.client_random
            target.server_random[:] = session.server_random
        hits, tested = (Hit * 256)(), u64()
        count = self.lib.tlsscan_scan(address(buffer) + at, length, base, step, threads, targets, len(sessions), hits, 256, ctypes.byref(tested))
        self.tested += tested.value
        return [Found(sessions[hit.target], hit) for hit in hits[: min(count, 256)]]

    def find(self, buffer, length, base, needles, threads=1, at=0):
        """The addresses where one of the 32 byte needles is, as (address, index of the needle)."""
        if not needles or length < 32:
            return []
        joined = b"".join(needles)
        found, which = (u64 * 4096)(), (u32 * 4096)()
        count = self.lib.tlsscan_find(address(buffer) + at, length, base, joined, len(needles), threads, found, which, 4096)
        return [(found[i], which[i]) for i in range(min(count, 4096))]


NET = "net.pcapng"
SENT = "0x00000002"
# The first bytes of each direction hold the hellos and the first encrypted records.
OPENING = 65536
PAGE = 4096
WANTED = {0x0301: {"CLIENT_RANDOM"}, 0x0302: {"CLIENT_RANDOM"}, 0x0303: {"CLIENT_RANDOM"},
          0x0304: {"CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0"}}
VERSIONS = {0x0301: "1.0", 0x0302: "1.1", 0x0303: "1.2", 0x0304: "1.3"}


def contiguous(parts):
    """The bytes from the first sequence number on, as far as nothing is missing, a retransmission laid over once."""
    data, expected = bytearray(), 1
    for seq, payload in sorted(parts, key=lambda part: part[0]):
        if seq > expected:
            break
        if seq + len(payload) > expected:
            data += payload[expected - seq:]
            expected = seq + len(payload)
    return bytes(data)


def openings(capture, streams):
    """What each side of these TCP streams sent first, as {stream: (the guest's bytes, the other side's)}."""
    pieces = {}
    if not streams:
        return {}
    display = f"tcp.len > 0 && tcp.seq < {OPENING} && tcp.stream in {{{', '.join(sorted(streams, key=int))}}}"
    for packet in capture.ek(NET, ["tcp.stream", "frame.packet_flags_direction", "tcp.seq", "tcp.payload"], display):
        try:
            seq, payload = int(first(packet, "tcp.seq")), bytes.fromhex(first(packet, "tcp.payload").replace(":", ""))
        except ValueError:
            continue
        side = 0 if first(packet, "frame.packet_flags_direction") == SENT else 1
        pieces.setdefault(first(packet, "tcp.stream"), ([], []))[side].append((seq, payload))
    return {stream: (contiguous(sides[0]), contiguous(sides[1])) for stream, sides in pieces.items()}


def keyed(capture):
    """The labels the capture's keys already have, by client random."""
    found = {}
    path = capture.keylog(None)
    if path:
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3:
                    found.setdefault(parts[1].lower(), set()).add(parts[0])
    return found


def sessions(capture, args, flows):
    """The TLS flows to look for: those of the window and of --flow, without keys unless --again, each with its session."""
    hello = {first(p, "tcp.stream") for p in capture.ek(NET, ["tcp.stream"], " && ".join(
        f"({part})" for part in (capture.window(args), "tls.handshake.type == 1") if part))}
    chosen = [flow for flow in flows if flow["proto"] == "tcp" and flow["id"][1:] in hello and (not args.flow or flow["id"] in args.flow)]
    data, have, picked = openings(capture, {flow["id"][1:] for flow in chosen}), keyed(capture), []
    for flow in chosen:
        guest, other = data.get(flow["id"][1:], (b"", b""))
        found = tlsrecords.session(guest, other)
        if found:
            found.guest_is_client = True
        else:
            found = tlsrecords.session(other, guest)
            if found:
                found.guest_is_client = False
        if not found:
            continue
        found.flow, found.found = flow, {}
        if not args.again and WANTED[found.version] <= have.get(found.client_random.hex(), set()):
            continue
        picked.append(found)
    return picked


class PteEntry(ctypes.Structure):
    _fields_ = [("vaBase", u64), ("cPages", u64), ("fPage", u64), ("fWoW64", u32), ("_FutureUse1", u32), ("uszText", ctypes.c_char_p),
                ("_Reserved1", u32), ("cSoftware", u32)]


class PteMap(ctypes.Structure):
    _fields_ = [("dwVersion", u32), ("_Reserved1", u32 * 5), ("pbMultiText", ctypes.c_void_p), ("cbMultiText", u32), ("cMap", u32)]


# From vmmdll.h: the page table map's version, a writable page, reads that go to the memory itself and give zeros for
# what is not there instead of reading the guest's page file, and the refresh of one process, by its number in the low
# half, without which MemProcFS keeps the page map it made first and misses pages mapped since.
PTE_VERSION, PAGE_WRITABLE, READ, REFRESH_PROCESS = 2, 0x2, 0x0001 | 0x0002 | 0x0010, 0x2002000300000000
USER_TOP = 0x0000800000000000


class Process:
    """The present, writable pages of a Windows process, read through MemProcFS."""

    def __init__(self, windows, pid):
        self.windows, self.pid = windows, pid
        vmm = windows.vmm
        vmm.VMMDLL_Map_GetPteU.argtypes = [ctypes.c_void_p, u32, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(PteMap))]
        vmm.VMMDLL_MemReadEx.argtypes = [ctypes.c_void_p, u32, u64, ctypes.c_void_p, u32, ctypes.POINTER(u32), u64]
        try:
            self.name = windows.process(pid)[0]
        except LookupError:
            self.name = "?"

    def __str__(self):
        return f"{plain(self.name, 80)}[{self.pid}]"

    def ranges(self):
        """(address, length) of each run of present writable pages of the process, as they are now."""
        vmm, pointer = self.windows.vmm, ctypes.POINTER(PteMap)()
        vmm.VMMDLL_ConfigSet(self.windows.handle, REFRESH_PROCESS | self.pid, 1)
        if not vmm.VMMDLL_Map_GetPteU(self.windows.handle, self.pid, 0, ctypes.byref(pointer)):
            raise LookupError(f"MemProcFS gave no page map of process {self.pid}")
        try:
            header = pointer.contents
            if header.dwVersion != PTE_VERSION:
                raise LookupError(f"MemProcFS's page map has version {header.dwVersion}, not the one this was written for")
            entries = ctypes.cast(ctypes.addressof(header) + ctypes.sizeof(PteMap), ctypes.POINTER(PteEntry))
            found = []
            for i in range(header.cMap):
                entry = entries[i]
                if entry.fPage & PAGE_WRITABLE and entry.vaBase < USER_TOP:
                    if found and found[-1][0] + found[-1][1] == entry.vaBase:
                        found[-1] = (found[-1][0], found[-1][1] + entry.cPages * PAGE)
                    else:
                        found.append((entry.vaBase, entry.cPages * PAGE))
            return found
        finally:
            vmm.VMMDLL_MemFree(pointer)

    def regions(self, budget):
        """(address, buffer) for each run, read now, up to the budget in bytes."""
        vmm, read, left = self.windows.vmm, u32(), budget
        for start, length in self.ranges():
            length = min(length, left)
            if length <= 0:
                return
            buffer = bytearray(length)
            for at in range(0, length, 1 << 24):
                piece = min(1 << 24, length - at)
                vmm.VMMDLL_MemReadEx(self.windows.handle, self.pid, start + at, address(buffer) + at, piece, ctypes.byref(read), READ)
            left -= length
            yield start, buffer, length


# A line of QEMU's flat memory map for RAM, as the session's monitor gives it.
RAM_LINE = re.compile(r"^\s+([0-9a-f]{16})-([0-9a-f]{16}) \(prio \d+, ram\): (\S+)(?: @([0-9a-f]{16}))?", re.MULTILINE)


class Physical:
    """The guest's whole RAM, mapped from the memory file the session hands over, for any guest."""

    def __init__(self):
        device = os.environ.get("VM_INSPECT_DEVICE", "")
        parts = dict(part.split("=", 1) for part in device.removeprefix("qemu://").split(",") if "=" in part)
        if "ram" not in parts or "qmp" not in parts:
            shared.fail("this needs the session's memory, which only vm-lab or vm-inspect gives")
        with socket.socket(socket.AF_UNIX) as conn:
            conn.connect(parts["ram"])
            _, fds, _, _ = socket.recv_fds(conn, 16, 1)
        if not fds:
            shared.fail("the session handed over no memory")
        self.fd = fds[0]
        self.size = os.fstat(self.fd).st_size
        libc = ctypes.CDLL(None, use_errno=True)
        libc.mmap.restype, libc.mmap.argtypes = ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
        # Read only and shared: the guest's own pages, as they change, and nothing this side can write to them.
        self.base = libc.mmap(None, self.size, 1, 1, self.fd, 0)
        if self.base in (None, ctypes.c_void_p(-1).value):
            shared.fail(f"the guest's memory could not be mapped: {os.strerror(ctypes.get_errno())}")
        self.map = self.layout(parts["qmp"])

    def layout(self, path):
        """(guest address, offset in the file, length) of each stretch of RAM."""
        with socket.socket(socket.AF_UNIX) as conn:
            conn.connect(path)
            stream = conn.makefile("rwb")
            stream.readline()
            for request in ({"execute": "qmp_capabilities"}, {"execute": "human-monitor-command", "arguments": {"command-line": "info mtree -f"}}):
                stream.write(json.dumps(request).encode() + b"\n")
                stream.flush()
                answer = json.loads(stream.readline())
        text = answer.get("return", "") if isinstance(answer, dict) else ""
        found, name = [], None
        for line in RAM_LINE.finditer(text):
            start, end, region, offset = int(line.group(1), 16), int(line.group(2), 16), line.group(3), int(line.group(4) or "0", 16)
            name = name or (region if start == 0 else None)
            # Each of QEMU's views of memory lists the RAM again, and it is searched once.
            if region == name and offset + end - start + 1 <= self.size and (start, offset, end - start + 1) not in found:
                found.append((start, offset, end - start + 1))
        if not found:
            shared.fail("the guest's RAM is not in the session's memory map")
        return found

    def __str__(self):
        return "the guest's RAM"

    def regions(self, budget):
        for start, offset, length in self.map:
            yield start, self.base + offset, length


def threads():
    return max(1, min(32, len(os.sched_getaffinity(0))))


def step_for(args, total):
    """The step asked for, or every offset where the memory is small enough, since some libraries keep their secrets at odd
    places, and every eighth beyond that."""
    return args.step or (1 if total <= 32 << 20 else 8)


def search(scanner, source, picked, args):
    """Looks for the secrets of the sessions in one source: around their client randoms, then, for those still without
    their keys and unless the source is the whole RAM without --deep, everywhere at the step."""
    regions = list(source.regions(args.max_memory << 20))
    total = sum(length for _, _, length in regions)
    print(f"guest-net: {source}: {size(total)} to search for {len(picked)} flows", file=sys.stderr)
    found, started = [], time.monotonic()
    places = 0
    for start, buffer, length in regions:
        for spot, which in scanner.find(buffer, length, start, [s.client_random for s in picked], threads()):
            places += 1
            low, high = max(start, spot - args.around), min(start + length, spot + 32 + args.around)
            found += scanner.scan(buffer, high - low, low, [picked[which]], step=1, threads=threads(), at=low - start)
    took(found, picked)
    left = [s for s in picked if not WANTED[s.version] <= set(s.found)]
    print(f"guest-net: {places} places of the client randoms, {sum(1 for s in picked if s not in left)} flows found around them "
          f"in {time.monotonic() - started:.1f} s", file=sys.stderr)
    if left and (args.deep or not isinstance(source, Physical)):
        started, step = time.monotonic(), step_for(args, total)
        for start, buffer, length in regions:
            found += scanner.scan(buffer, length, start, left, step=step, threads=threads())
            took(found, left)
            left = [s for s in left if not WANTED[s.version] <= set(s.found)]
            if not left:
                break
        print(f"guest-net: the rest at step {step}: {scanner.tested} candidates in {time.monotonic() - started:.1f} s", file=sys.stderr)
    return found


def took(found, picked):
    for hit in found:
        if hit.session in picked:
            hit.session.found.setdefault(hit.label, hit)


def owner(flow, live):
    """The process a flow belonged to: as owners saw it, or as the guest's memory shows it now."""
    matched = re.search(r"\[(\d+)\]$", flow.get("owner") or "")
    if matched:
        return int(matched.group(1))
    for entry in live:
        if entry["proto"] == "tcp" and entry["local"] == flow["guest"] and entry["remote"] in ("", flow["remote"]):
            return entry["pid"]
    return None


def run(capture, args, flows):
    scanner = Scanner(shared.SETTINGS.scan)
    if args.follow:
        Follower(capture, args, scanner).run()
        return
    picked = sessions(capture, args, flows)
    for s in [s for s in picked if not scanner.supported(s)]:
        print(f"{s.flow['id']}: TLS {s.version:#06x} with suite {s.suite:#06x} is not one keys scan knows", file=sys.stderr)
    picked = [s for s in picked if scanner.supported(s)]
    if not picked:
        print("there is no TLS flow without keys to look for" + ("" if args.again else ", --again looks again for those with keys"))
        return
    if args.physical:
        groups = [(Physical(), picked)]
    else:
        try:
            memory = owners.Memory()
        except (LookupError, OSError) as e:
            shared.fail(f"{e}. Without Windows, --physical searches the guest's whole RAM")
        if args.process:
            pids = [memory.windows.pid(name) for name in args.process]
            groups = [(Process(memory.windows, pid), picked) for pid in pids]
        else:
            live, by = memory.sample(), {}
            for s in picked:
                by.setdefault(owner(s.flow, live), []).append(s)
            for s in by.pop(None, []):
                print(f"{s.flow['id']}: its program is not known, owners --follow while it runs finds it, or --process names it", file=sys.stderr)
            groups = [(Process(memory.windows, pid), group) for pid, group in by.items()]
    for source, group in groups:
        try:
            search(scanner, source, group, args)
        except LookupError as e:
            print(f"guest-net: {source}: {e}", file=sys.stderr)
    lines = [hit.line for s in picked for hit in s.found.values()]
    for at in range(0, len(lines), 4096):
        tell({"do": "note", "kind": "keys", "lines": lines[at: at + 4096]})
    for s in picked:
        names = plain(",".join(s.flow["names"]) or s.flow["remote"], 60)
        if s.found:
            where = ", ".join(f"{label} at {hit.address:#x}" for label, hit in sorted(s.found.items()))
            print(f"{s.flow['id']:<6} {names}  TLS {VERSIONS[s.version]}  {where}")
        else:
            print(f"{s.flow['id']:<6} {names}  TLS {VERSIONS[s.version]}  not found")
    print(f"{len(lines)} secrets added to the capture", file=sys.stderr)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(shared.SETTINGS.dbg, f"{name}.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Pause:
    """The whole guest held still through QEMU's debug stub while memory is copied, for programs that close at once. The
    stub takes one client, so this cannot run beside keys schannel or guest-gdb."""

    def __init__(self):
        target = os.environ.get("VM_INSPECT_GDB")
        if not target:
            shared.fail("--pause needs the session's debug stub, which vm-lab opens")
        self.mi = load("mi")
        self.gdb = self.mi.Gdb(shared.SETTINGS.gdb)
        try:
            for setting in ("mi-async on", "pagination off", "confirm off"):
                self.gdb.run(f"-gdb-set {setting}")
            self.gdb.run(f"-target-select remote {target}", wait=60)
            self.gdb.stops.clear()
            self.gdb.run("-exec-continue")
        except self.mi.Failed as e:
            shared.fail(f"the debug stub did not take this, it may be in use: {e}")

    def hold(self):
        self.gdb.run("-exec-interrupt")
        if self.gdb.stopped(time.monotonic() + 10) is None:
            raise self.mi.Failed("the guest did not stop")

    def release(self):
        self.gdb.run("-exec-continue")

    def close(self):
        try:
            self.gdb.run("-target-detach")
            self.gdb.run("-gdb-exit", wait=5)
        except self.mi.Failed:
            pass
        self.gdb.close()


# MemProcFS's refreshes of its page table cache and of its process list, from vmmdll.h.
REFRESH_TLB, REFRESH_PROCESSES = 0x2001080000000000, 0x2001000100000000


class Pending:
    """A flow whose memory was copied when its client began to encrypt, kept until its records tell the secrets."""

    def __init__(self, flow, windows, whole, source):
        self.flow, self.windows, self.whole, self.source = flow, windows, whole, source
        self.since, self.told, self.records, self.searched = time.monotonic(), set(), 0, ""


class Flow:
    """What follow knows of one TCP connection: its two ends, where each side's sequence numbers began, and the bytes each
    sent first."""

    def __init__(self, guest, remote):
        self.guest, self.remote, self.pieces, self.start = guest, remote, ([], []), [None, None]
        # How many records the client had encrypted when the server's first encrypted record came.
        self.before = None
        self.trigger = time.time()

    def session(self):
        guest, other = (contiguous(side) for side in self.pieces)
        return tlsrecords.session(guest, other) or tlsrecords.session(other, guest)

    def __str__(self):
        return f"{self.guest} -> {self.remote}"


class Follower:
    """keys scan --follow: copies the memory of each new TLS flow's program as soon as its client sends its first encrypted
    record, when the secrets are surely there, and checks the copy as the flow's records come in. Flows that begin
    together are copied together, one read of each program, since a browser opens many at once and closes them soon."""

    PATIENCE = 30

    def __init__(self, capture, args, scanner):
        self.capture, self.args, self.scanner = capture, args, scanner
        self.flows, self.pending, self.handled, self.ready, self.later = {}, {}, set(), [], []
        self.memory = self.physical = self.pause = None
        if args.physical:
            self.physical = Physical()
        else:
            try:
                self.memory = owners.Memory()
            except (LookupError, OSError) as e:
                shared.fail(f"{e}. Without Windows, --physical searches the guest's whole RAM")
        if args.pause:
            self.pause = Pause()
        self.failures = (LookupError, self.pause.mi.Failed) if self.pause else (LookupError,)

    def run(self):
        reader = self.reader = packets.follow(self.capture.file(NET))
        until = time.monotonic() + self.args.seconds if self.args.seconds else None
        print(f"guest-net: following the capture for new TLS flows{', holding the guest while copying' if self.pause else ''}, Ctrl-C ends it",
              file=sys.stderr)
        checked = 0.0
        try:
            while until is None or time.monotonic() < until:
                fresh = reader.poll()
                for packet in fresh:
                    self.packet(packet)
                # A batch is copied once the capture has nothing more at hand, or when it is large. The copies are checked
                # only when no flow waits to be copied, since a short lived connection is lost while the copy waits.
                if self.ready and (not fresh or len(self.ready) >= 64):
                    batch, self.ready = self.ready, []
                    self.copy(batch)
                elif self.later and not fresh:
                    self.take([self.later.pop(0)])
                elif not fresh and time.monotonic() - checked > 0.3:
                    for key, pending in list(self.pending.items()):
                        self.check(pending, key)
                    self.expire()
                    checked = time.monotonic()
                    if self.capture.ended():
                        break
                elif not fresh:
                    time.sleep(0.002)
        except KeyboardInterrupt:
            pass
        finally:
            reader.close()
            if self.pause:
                self.pause.close()
        self.expire(final=True)

    def packet(self, packet):
        """Takes one packet into its connection, and puts the connection up for copying once its client has begun to
        encrypt. A connection is followed from its SYN, so that its sequence numbers can be placed."""
        key, side = (packet.guest, packet.remote), 0 if packet.sent else 1
        flow = self.flows.get(key)
        if packet.syn:
            if flow is None or (flow.start[side] is not None and flow.start[side] != packet.seq):
                flow = self.flows[key] = Flow(packet.guest, packet.remote)
                self.handled.discard(key)
                self.pending.pop(key, None)
            flow.start[side] = packet.seq
            return
        if flow is None or flow.start[side] is None or not packet.payload:
            return
        seq = (packet.seq - flow.start[side]) & 0xFFFFFFFF
        if seq >= OPENING:
            return
        flow.pieces[side].append((seq, packet.payload))
        if key in self.handled:
            return
        found = flow.session()
        client = sum(1 for record in found.records if record[0] == 0) if found else 0
        if found and found.version == 0x0304 and flow.before is None and any(record[0] == 1 for record in found.records):
            flow.before = client
        # The traffic secrets of TLS 1.3 are there once the client encrypts after the server's flight: its records before
        # that can be early data, sent with the hello. Those of the older versions are there with the client's first.
        if found and client and (found.version != 0x0304 or (flow.before is not None and client > flow.before)):
            self.handled.add(key)
            flow.trigger = packet.time
            if self.scanner.supported(found):
                self.ready.append((key, found))
            else:
                print(f"{flow}: TLS {found.version:#06x} with suite {found.suite:#06x} is not one keys scan knows", file=sys.stderr)

    def copy(self, batch):
        """Copies the memory that may hold the secrets of a batch of flows: around their client randoms in the memory of their
        programs, or in the whole RAM. A program larger than --keep waits until nothing else does, since its copy is slow and
        holds back the copies of short lived connections, and the large ones, services mostly, keep theirs open."""
        if self.physical:
            self.take([(self.physical, batch)])
            return
        try:
            if self.pause:
                self.pause.hold()
                # What the capture gained before the guest stopped joins this batch, since the guest cannot close those
                # connections while it is held, and could right after.
                while fresh := self.reader.poll():
                    for packet in fresh:
                        self.packet(packet)
                batch, self.ready = batch + self.ready, []
            groups = self.owners(batch)
        except self.failures as e:
            print(f"guest-net: {e}", file=sys.stderr)
            return
        finally:
            if self.pause:
                self.pause.release()
        small = [(source, members) for source, members, total in groups if total <= self.args.keep << 20]
        self.later += [(source, members) for source, members, total in groups if total > self.args.keep << 20]
        if small:
            self.take(small)

    def take(self, groups):
        """Copies the memory of each group's program around its flows' client randoms, all of it when it is small enough."""
        held, waited = time.monotonic(), time.time() - min(self.flows[s].trigger for _, members in groups for s, _ in members)
        try:
            if self.pause:
                self.pause.hold()
            if not self.physical:
                self.memory.windows.vmm.VMMDLL_ConfigSet(self.memory.windows.handle, REFRESH_TLB, 1)
            copies = []
            for source, members in groups:
                regions = list(source.regions(0 if self.physical else self.args.max_memory << 20))
                windows = {stream: [] for stream, _ in members}
                for start, buffer, length in regions:
                    for spot, which in self.scanner.find(buffer, length, start, [found.client_random for _, found in members], threads()):
                        low, high = max(start, spot - self.args.around), min(start + length, spot + 32 + self.args.around)
                        windows[members[which][0]].append((low, ctypes.string_at(address(buffer) + low - start, high - low)))
                total = sum(length for _, _, length in regions)
                whole = regions if not self.physical and total <= self.args.keep << 20 else None
                copies.append((source, members, windows, whole))
        except self.failures as e:
            print(f"guest-net: {e}", file=sys.stderr)
            return
        finally:
            if self.pause:
                self.pause.release()
        took_ms = (time.monotonic() - held) * 1000
        for source, members, windows, whole in copies:
            print(f"guest-net: {len(members)} new flows of {source}, {sum(1 for w in windows.values() if w)} with their client random "
                  f"found{', all of its memory kept' if whole else ''}, copied {waited * 1000:.0f} ms after the handshake in {took_ms:.0f} ms",
                  file=sys.stderr)
            for stream, _ in members:
                self.pending[stream] = Pending(self.flows[stream], windows[stream], whole, source)

    def owners(self, batch):
        """The flows of a batch by the process their connection belongs to, as the guest's memory shows it now, which is
        also kept in the capture, with the size of each process's writable memory, smallest first."""
        windows, by = self.memory.windows, {}
        live = {entry["local"]: entry for entry in self.memory.sample() if entry["proto"] == "tcp"}
        # MemProcFS leaves out the connections of a process it does not know yet, as a program just started.
        if any(self.flows[stream].guest not in live for stream, _ in batch):
            windows.vmm.VMMDLL_ConfigSet(windows.handle, REFRESH_PROCESSES, 1)
            live = {entry["local"]: entry for entry in self.memory.sample() if entry["proto"] == "tcp"}
        for stream, found in batch:
            entry = live.get(self.flows[stream].guest)
            if entry is None:
                late = (time.time() - self.flows[stream].trigger) * 1000
                print(f"{self.flows[stream]} {plain(found.name or '', 60)}: closed before its program was seen, {late:.0f} ms after its handshake",
                      file=sys.stderr)
                continue
            by.setdefault(entry["pid"], []).append((stream, found))
        if not by:
            return []
        tell({"do": "note", "kind": "owners", "entries": [live[self.flows[s].guest] for group in by.values() for s, _ in group]})
        windows.vmm.VMMDLL_ConfigSet(windows.handle, REFRESH_TLB, 1)
        groups = []
        for pid, members in by.items():
            source = Process(windows, pid)
            groups.append((source, members, sum(length for _, length in source.ranges())))
        return sorted(groups, key=lambda group: group[2])

    def check(self, pending, stream, final=False):
        """Tries the copy against the flow's records when more have come, and adds what opens them. Whether it is done."""
        found = pending.flow.session()
        if not found:
            return False
        if len(found.records) == pending.records and not final:
            return WANTED[found.version] <= pending.told
        pending.records = len(found.records)
        hits = []
        for low, window in pending.windows:
            hits += self.scanner.scan(window, len(window), low, [found], step=1, threads=threads())
        labels = pending.told | {hit.label for hit in hits}
        # The whole copy is searched once, when the records the traffic secrets open have come.
        ready = final or found.version != 0x0304 or sum(1 for record in found.records if record[0] == 1) > 1
        if not WANTED[found.version] <= labels and pending.whole and ready:
            total = sum(length for _, _, length in pending.whole)
            step = step_for(self.args, total)
            for start, buffer, length in pending.whole:
                hits += self.scanner.scan(buffer, length, start, [found], step=step, threads=threads())
            pending.whole, pending.searched = None, f", {size(total)} searched at step {step}"
        fresh = {hit.label: hit for hit in hits if hit.label not in pending.told}
        if fresh:
            tell({"do": "note", "kind": "keys", "lines": [hit.line for hit in fresh.values()]})
            pending.told |= set(fresh)
            print(f"{pending.flow}  {plain(found.name or '-', 60)}  TLS {VERSIONS[found.version]}  "
                  f"{', '.join(sorted(fresh))} in {pending.source}")
            sys.stdout.flush()
        done = WANTED[found.version] <= pending.told
        if done:
            del self.pending[stream]
        return done

    def expire(self, final=False):
        """Lets go of flows that have waited long enough for their records, saying of those without secrets."""
        for stream, pending in list(self.pending.items()):
            late = final or time.monotonic() - pending.since > self.PATIENCE
            if late and not self.check(pending, stream, final=True):
                found = pending.flow.session()
                counts = [sum(1 for record in found.records if record[0] == side) for side in (0, 1)] if found else [0, 0]
                # A client that sent only its Finished has nothing its traffic secret could open, nor anything to decrypt.
                if pending.told == {"SERVER_TRAFFIC_SECRET_0"} and counts[0] <= 1:
                    self.pending.pop(stream, None)
                    continue
                print(f"{pending.flow} {plain(getattr(found, 'name', '') or '-', 60)}: "
                      f"{'only ' + ', '.join(sorted(pending.told)) if pending.told else 'its secrets were not in the copy'} "
                      f"({len(pending.windows)} places of its client random{pending.searched}, {counts[0]} records of the client and "
                      f"{counts[1]} of the server{', early data offered' if getattr(found, 'early', False) else ''})", file=sys.stderr)
                self.pending.pop(stream, None)

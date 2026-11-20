"""keys scan: the TLS secrets of any program in the guest, found in its memory from outside and checked against the capture.

A program that talks TLS keeps the secrets of each connection in its memory while the connection lasts, since TLS 1.3
needs them to update its keys. This reads that memory without the guest seeing it, tries the windows that could be
secrets against the flow's own encrypted records, and adds to the capture only what opens them. The libraries most
programs use keep the client random beside the secrets, so its places in memory are searched first.

The search runs in libtlsscan, in C on libcrypto, since it tries millions of windows.
"""
import bisect
import ctypes
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import time

import capture as shared
import owners
import packets
import quiclate
import tlsrecords
from capture import first, plain, size, tell

u32, u64 = ctypes.c_uint32, ctypes.c_uint64


class Record(ctypes.Structure):
    _fields_ = [("direction", u32), ("type", u32), ("version", u32), ("length", u32), ("body", ctypes.c_void_p), ("number", u64)]


class Target(ctypes.Structure):
    _fields_ = [("version", u32), ("suite", u32), ("etm", u32), ("nrecords", u32), ("records", ctypes.POINTER(Record)),
                ("client_random", ctypes.c_uint8 * 32), ("server_random", ctypes.c_uint8 * 32), ("quic", u32)]


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
        direction = session.records[hit.record][0]
        index = sum(1 for r in session.records[: hit.record] if r[0] == direction)
        self.session, self.address, self.direction, self.index, self.later = session, hit.address, direction, index, False
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
        lib.tlsscan_quic_initial.restype = ctypes.c_long
        lib.tlsscan_quic_initial.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_size_t, u32, ctypes.c_char_p, ctypes.c_size_t,
                                             ctypes.c_int, ctypes.c_char_p, ctypes.c_size_t]
        lib.tlsscan_open13.restype = ctypes.c_long
        lib.tlsscan_open13.argtypes = [u32, ctypes.c_char_p, u64, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
        lib.tlsscan_next13.restype = ctypes.c_int
        lib.tlsscan_next13.argtypes = [u32, ctypes.c_char_p, ctypes.c_char_p]
        lib.tlsscan_quic_late.restype = ctypes.c_long
        lib.tlsscan_quic_late.argtypes = [u32, u32, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_size_t, u64, u64, ctypes.c_int,
                                          ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(u32), ctypes.POINTER(u64)]
        lib.tlsscan_quic_next.restype = ctypes.c_int
        lib.tlsscan_quic_next.argtypes = [u32, u32, ctypes.c_char_p, ctypes.c_char_p]
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
            # A packet after QUIC's key updates has a fifth, the least packet number it can have.
            for record, (direction, kind, version, body, *number) in zip(records, session.records):
                record.direction, record.type, record.version, record.length, record.body = direction, kind, version, len(body), address(body)
                record.number = number[0] if number else 0
                kept.append(body)
            kept.append(records)
            target.version, target.suite, target.etm, target.nrecords = session.version, session.suite, int(session.etm), len(session.records)
            target.records = records
            target.client_random[:] = session.client_random
            target.server_random[:] = session.server_random or bytes(32)
            target.quic = session.quic
        hits, tested = (Hit * 256)(), u64()
        count = self.lib.tlsscan_scan(address(buffer) + at, length, base, step, threads, targets, len(sessions), hits, 256, ctypes.byref(tested))
        self.tested += tested.value
        return [Found(sessions[hit.target], hit) for hit in hits[: min(count, 256)]]

    def quic_initial(self, packet, at, version, destination, from_server):
        """The plaintext of a QUIC Initial packet, or None."""
        out = ctypes.create_string_buffer(len(packet))
        count = self.lib.tlsscan_quic_initial(packet, len(packet), at, version, destination, len(destination), int(from_server), out, len(packet))
        return out.raw[:count] if count >= 0 else None

    def open13(self, suite, secret, seq, record):
        """The plaintext of a record of TLS 1.3, header included, under a traffic secret at a sequence number, inner type and
        padding still on it, or None."""
        out = ctypes.create_string_buffer(len(record))
        count = self.lib.tlsscan_open13(suite, secret, seq, record, len(record), out, len(record))
        return out.raw[:count] if count >= 0 else None

    def next13(self, suite, secret):
        """The secret a key update turns this one into."""
        out = ctypes.create_string_buffer(48)
        count = self.lib.tlsscan_next13(suite, secret, out)
        return out.raw[:count]

    def quic_late(self, version, suite, secret, packet, at, low, count, any_frame=False):
        """A short QUIC packet opened with a traffic secret after key updates, its packet number tried from low on for count
        numbers, as (plaintext, key phase, packet number), or None. any_frame tries every way to open it, also those whose
        plaintext begins with no frame keys scan looks for."""
        out, phase, number = ctypes.create_string_buffer(len(packet)), u32(), u64()
        length = self.lib.tlsscan_quic_late(version, suite, secret, packet, len(packet), at, low, count, int(any_frame), out, len(packet),
                                            ctypes.byref(phase), ctypes.byref(number))
        return (out.raw[:length], phase.value, number.value) if length >= 0 else None

    def quic_next(self, version, suite, secret):
        """The secret a QUIC key update turns this one into."""
        out = ctypes.create_string_buffer(48)
        count = self.lib.tlsscan_quic_next(version, suite, secret, out)
        return out.raw[:count]

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
# How much of each side of a TLS 1.3 flow that updated its keys is read, to reach the record after its last update.
WHOLE = 64 << 20


def roles(labels):
    return {label.split("_", 1)[0] for label in labels}


def finished(session):
    """Whether a session has what it is searched for: the labels of its version, or for one of the newest keys a secret for
    each direction it has records of, whichever of them it opened."""
    if session.epochs:
        return {("CLIENT", "SERVER")[direction] for direction, *_ in session.records} <= roles(session.found)
    return WANTED[session.version] <= set(session.found)


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


def laid(parts):
    """The bytes from the first sequence number on, as far as nothing is missing, with where each packet's bytes end in them
    and when it came."""
    data, marks, expected = bytearray(), [], 1
    for seq, payload, when in sorted(parts, key=lambda part: part[0]):
        if seq > expected:
            break
        if seq + len(payload) > expected:
            data += payload[expected - seq:]
            expected = seq + len(payload)
            marks.append((len(data), when))
    return bytes(data), marks


def whole(capture, streams, limit=WHOLE):
    """What each side of these TCP streams sent, up to the limit, as {stream: ((the guest's bytes, marks), (the other side's, marks))}."""
    pieces = {}
    if not streams:
        return {}
    display = f"tcp.len > 0 && tcp.seq < {limit} && tcp.stream in {{{', '.join(sorted(streams, key=int))}}}"
    for packet in capture.ek(NET, ["tcp.stream", "frame.packet_flags_direction", "tcp.seq", "tcp.payload", "frame.time_epoch"], display):
        try:
            seq, payload = int(first(packet, "tcp.seq")), bytes.fromhex(first(packet, "tcp.payload").replace(":", ""))
            when = float(first(packet, "frame.time_epoch", "0"))
        except ValueError:
            continue
        side = 0 if first(packet, "frame.packet_flags_direction") == SENT else 1
        pieces.setdefault(first(packet, "tcp.stream"), ([], []))[side].append((seq, payload, when))
    return {stream: (laid(sides[0]), laid(sides[1])) for stream, sides in pieces.items()}


def updated(capture):
    """The secrets after key updates the capture has, as {client random: {label: secret}}."""
    found = {}
    try:
        with open(os.path.join(capture.folder, "updated.log")) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3 and shared.UPDATED.fullmatch(line.strip()):
                    found.setdefault(parts[1].lower(), {})[parts[0]] = bytes.fromhex(parts[2])
    except OSError:
        pass
    return found


def newer_sessions(capture, args, picked, broad=False):
    """For the TLS 1.3 flows that updated their keys, a session of their newest keys each, which is all a program holds once
    it updated them: the records the newest secret of each direction may begin at. Without broad only flows with a record
    the size of a KeyUpdate, with broad every one given, for KeyUpdates sent padded."""
    latest = {s.flow["id"][1:]: s for s in picked if s.version == 0x0304 and not s.quic}
    if not latest:
        return []
    sizes = sorted({tlsrecords.update_size(s.suite) for s in latest.values()})
    if broad:
        streams = set(latest)
    else:
        display = f"tls.record.length in {{{', '.join(map(str, sizes))}}} && tcp.stream in {{{', '.join(sorted(latest, key=int))}}}"
        streams = {first(p, "tcp.stream") for p in capture.ek(NET, ["tcp.stream"], display)}
    have, out = updated(capture), []
    for stream, ((guest, _), (other, _)) in whole(capture, streams).items():
        s = latest[stream]
        newer = tlsrecords.late(s, *((guest, other) if s.guest_is_client else (other, guest)), broad=broad)
        sides = {("CLIENT", "SERVER")[direction] for direction, *_ in newer.records} if newer else set()
        if newer is None or (not args.again and sides <= roles(have.get(newer.client_random.hex(), {}))):
            continue
        newer.flow, newer.found, newer.guest_is_client = s.flow, {}, s.guest_is_client
        out.append(newer)
    return out


def openings(capture, streams):
    """What each side of these TCP streams sent first, as {stream: ((the guest's bytes, marks), (the other side's, marks))},
    with marks as laid() gives them."""
    pieces = {}
    if not streams:
        return {}
    display = f"tcp.len > 0 && tcp.seq < {OPENING} && tcp.stream in {{{', '.join(sorted(streams, key=int))}}}"
    for packet in capture.ek(NET, ["tcp.stream", "frame.packet_flags_direction", "tcp.seq", "tcp.payload", "frame.time_epoch"], display):
        try:
            seq, payload = int(first(packet, "tcp.seq")), bytes.fromhex(first(packet, "tcp.payload").replace(":", ""))
            when = float(first(packet, "frame.time_epoch", "0"))
        except ValueError:
            continue
        side = 0 if first(packet, "frame.packet_flags_direction") == SENT else 1
        pieces.setdefault(first(packet, "tcp.stream"), ([], []))[side].append((seq, payload, when))
    return {stream: (laid(sides[0]), laid(sides[1])) for stream, sides in pieces.items()}


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
        (guest, guest_marks), (other, other_marks) = data.get(flow["id"][1:], ((b"", []), (b"", [])))
        found = tlsrecords.session(guest, other)
        if found:
            found.guest_is_client, found.sides = True, ((guest, guest_marks), (other, other_marks))
        else:
            found = tlsrecords.session(other, guest)
            if found:
                found.guest_is_client, found.sides = False, ((other, other_marks), (guest, guest_marks))
        if not found:
            continue
        found.flow, found.found = flow, {}
        if not args.again and WANTED[found.version] <= have.get(found.client_random.hex(), set()):
            continue
        picked.append(found)
    # A flow whose first keys are known needs no newer ones, since tshark follows its updates from those.
    return picked + newer_sessions(capture, args, picked) + quic_sessions(capture, args, flows, have)


# The packets of a QUIC flow's first seconds hold its handshake and its first packets under the traffic secrets.
QUIC_OPENING = 10


def quic_hellos(capture, display="", keys=None):
    """What tshark reads of the hellos in QUIC's Initial packets, which it opens by itself, by UDP stream: {stream: {"time",
    "random", "guest_is_client", "name", "port", "suite"}}, of the flows the display filter keeps, port being the server's."""
    hellos = {}
    display = " && ".join(f"({part})" for part in (display, "quic && (tls.handshake.type == 1 || tls.handshake.type == 2)") if part)
    for packet in capture.ek(NET, ["udp.stream", "frame.time_epoch", "frame.packet_flags_direction", "tls.handshake.type",
                                   "tls.handshake.random", "tls.handshake.extensions_server_name", "tls.handshake.ciphersuite", "udp.dstport"],
                           display, keys):
        hello = hellos.setdefault(first(packet, "udp.stream"), {"time": float(first(packet, "frame.time_epoch", "0"))})
        kinds = packet["tls.handshake.type"]
        if "1" in kinds and packet["tls.handshake.random"] and "random" not in hello:
            hello["random"] = bytes.fromhex(first(packet, "tls.handshake.random").replace(":", ""))
            hello["guest_is_client"] = first(packet, "frame.packet_flags_direction") == SENT
            hello["name"], hello["port"] = first(packet, "tls.handshake.extensions_server_name"), first(packet, "udp.dstport")
        elif "2" in kinds and packet["tls.handshake.ciphersuite"]:
            hello["suite"] = int(first(packet, "tls.handshake.ciphersuite"), 0)
    return hellos


def quic_sessions(capture, args, flows, have):
    """The QUIC flows to look for, with the client random and the suite tshark read from the Initial packets, which it opens
    by itself, and the flow's first datagrams, whose other packets the secrets have to open."""
    hellos = quic_hellos(capture, capture.window(args))
    by_id = {flow["id"]: flow for flow in flows}
    chosen = {stream: hello for stream, hello in hellos.items() if "random" in hello and "suite" in hello and f"u{stream}" in by_id
              and (not args.flow or f"u{stream}" in args.flow)
              and (args.again or not WANTED[0x0304] <= have.get(hello["random"].hex(), set()))}
    taken, picked = datagrams_of(capture, {stream: hello["time"] + QUIC_OPENING for stream, hello in chosen.items()}), []
    for stream in sorted(chosen, key=int):
        sides = [(0 if from_guest == chosen[stream]["guest_is_client"] else 1, data) for from_guest, data in taken.get(stream, [])]
        found = tlsrecords.quic_session(sides, chosen[stream]["random"], chosen[stream]["suite"])
        if found:
            found.flow, found.found, found.guest_is_client = by_id[f"u{stream}"], {}, chosen[stream]["guest_is_client"]
            picked.append(found)
    return picked


def datagrams_of(capture, until, fields=(), limit=WHOLE):
    """The datagrams of UDP streams in order, as {stream: [(whether the guest sent it, its payload, *the fields)]}: of each
    stream of until those up to its time, or all when that is None, and no more than the limit of bytes."""
    found, sizes, streams = {}, {}, sorted(until, key=int)
    for at in range(0, len(streams), 50):
        display = " || ".join(f"(udp.stream == {s}" + (f" && frame.time_epoch <= {until[s]:.6f})" if until[s] is not None else ")")
                              for s in streams[at: at + 50])
        for packet in capture.ek(NET, ["udp.stream", "frame.packet_flags_direction", "udp.payload", *fields], display):
            try:
                data = bytes.fromhex(first(packet, "udp.payload").replace(":", ""))
            except ValueError:
                continue
            stream = first(packet, "udp.stream")
            sizes[stream] = sizes.get(stream, 0) + len(data)
            if sizes[stream] <= limit:
                found.setdefault(stream, []).append((first(packet, "frame.packet_flags_direction") == SENT, data, *(first(packet, f) for f in fields)))
    return found


def late_quic_sessions(capture, args, picked):
    """For the QUIC flows whose first traffic secrets are not found, a session of their newest keys each, for the directions
    still without them: a few of their last short packets, which a secret after key updates opens. No packet shows an
    update, since the key phase bit is under the header's protection, so this is tried only once the first secrets are not
    there."""
    chosen = {s.flow["id"][1:]: s for s in picked}
    taken, have, out = datagrams_of(capture, dict.fromkeys(chosen)), updated(capture), []
    for stream, s in chosen.items():
        sides = [(0 if from_guest == s.guest_is_client else 1, data) for from_guest, data in taken.get(stream, [])]
        missing = [direction for direction, role in enumerate(("CLIENT", "SERVER")) if f"{role}_TRAFFIC_SECRET_0" not in s.found]
        newer = tlsrecords.quic_late(sides, s, missing)
        wanted = {("CLIENT", "SERVER")[direction] for direction, *_ in newer.records} if newer else set()
        if newer is None or (not args.again and wanted <= roles(have.get(newer.client_random.hex(), {}))):
            continue
        newer.flow, newer.found, newer.guest_is_client, newer.datagrams = s.flow, {}, s.guest_is_client, sides
        out.append(newer)
    return out


def acknowledged_sessions(scanner, picked):
    """For the sessions of QUIC's newest keys that found the secret of one side only, (the session, one of the other side's
    last packets at the numbers the side found acknowledged): packets lost on the way put the real numbers past where
    their place in the capture says, as far as a long connection lost."""
    out = []
    for s in picked:
        known = [direction for direction, role in enumerate(("CLIENT", "SERVER")) if role in roles(s.found)]
        if len(known) != 1:
            continue
        known, other = known[0], 1 - known[0]
        parts = quiclate.split(s.datagrams)
        side = quiclate.Side(scanner, s.quic, s.suite, parts[known])
        side.read([hit.secret for label, hit in s.found.items() if label.startswith(("CLIENT_", "SERVER_")[known])])
        newer = tlsrecords.Session()
        newer.__dict__.update(s.__dict__, found={}, records=[])
        # The packet before an acknowledgement may still have been on its way to the program, so its number is that one or more.
        for index, number in quiclate.hints(side, parts[other])[: tlsrecords.LATE_PICKED]:
            _, lowest, at, packet, _ = parts[other][index]
            newer.records.append((other, tlsrecords.LATE_PACKET, at, packet, max(lowest, number - 2)))
        if newer.records:
            out.append((s, newer))
    return out


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

    def at(self, address):
        """Where a page of the guest's RAM is mapped on this side, or None."""
        for start, offset, length in self.map:
            if start <= address < start + length:
                return self.base + offset + address - start
        return None


# Run by the agent in a guest that is not Windows: each writable mapping of the process, then the entries of its page map,
# which name the physical page of each virtual one when read as root.
PAGES = r"""
pid=$1
echo "name $(cat /proc/$pid/comm)"
grep -E '^[0-9a-f]+-[0-9a-f]+ rw' /proc/$pid/maps | while read -r range rest; do
  a=${range%-*}; b=${range#*-}
  echo "range $a $b"
  dd if=/proc/$pid/pagemap bs=8 skip=$((0x$a / 4096)) count=$(((0x$b - 0x$a) / 4096)) 2>/dev/null | od -An -v -tx8
done
"""
PRESENT, FRAME = 1 << 63, (1 << 55) - 1


class Pagemap:
    """The present, writable pages of a process of a guest that is not Windows, found in its own /proc through the agent,
    which the guest sees, and read from the RAM in the program's order, so that a secret split across two pages is whole."""

    def __init__(self, ram, pid):
        self.ram, self.pid, self.name = ram, pid, "?"

    def __str__(self):
        return f"{plain(self.name, 80)}[{self.pid}]"

    def regions(self, budget):
        done = subprocess.run(["guest-exec", "--timeout", "120", "--max", "256M", "/bin/sh", "-c", PAGES, "sh", str(self.pid)],
                              capture_output=True, text=True, errors="replace", check=False)
        if done.returncode != 0 or "range " not in done.stdout:
            raise LookupError(f"the agent read no page map of process {self.pid}: {plain(done.stderr.strip()[-300:], 300)}")
        spans, frames = [], None
        for line in done.stdout.splitlines():
            words = line.split()
            if words[:1] == ["name"]:
                self.name = " ".join(words[1:])
            elif words[:1] == ["range"] and len(words) == 3:
                frames = []
                spans.append((int(words[1], 16), int(words[2], 16), frames))
            elif frames is not None:
                frames += [int(word, 16) for word in words if len(word) == 16]
        found = []
        for start, end, entries in spans:
            if budget <= 0:
                break
            length = min(end - start, budget, len(entries) * PAGE)
            buffer = bytearray(length)
            for page, entry in enumerate(entries[: length // PAGE]):
                where = self.ram.at((entry & FRAME) * PAGE) if entry & PRESENT and entry & FRAME else None
                if where:
                    ctypes.memmove(address(buffer) + page * PAGE, where, PAGE)
            budget -= length
            found.append((start, buffer, length))
        if found and not any(any(entry & FRAME for entry in entries) for _, _, entries in spans):
            raise LookupError("the page map names no physical pages, so the agent does not run as root")
        return found


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
    left = [s for s in picked if not finished(s)]
    print(f"guest-net: {places} places of the client randoms, {sum(1 for s in picked if s not in left)} flows found around them "
          f"in {time.monotonic() - started:.1f} s", file=sys.stderr)
    if left and (args.deep or not isinstance(source, Physical)):
        started, step = time.monotonic(), step_for(args, total)
        for start, buffer, length in regions:
            found += scanner.scan(buffer, length, start, left, step=step, threads=threads())
            took(found, left)
            left = [s for s in left if not finished(s)]
            if not left:
                break
        print(f"guest-net: the rest at step {step}: {scanner.tested} candidates in {time.monotonic() - started:.1f} s", file=sys.stderr)
    return found


def took(found, picked):
    for hit in found:
        if hit.session in picked:
            hit.session.found.setdefault(hit.label, hit)


def arrived(marks, end):
    """When the packet came that brought the byte before this offset, by laid()'s marks."""
    at = bisect.bisect_left(marks, (end,))
    return marks[min(at, len(marks) - 1)][1] if marks else 0.0


def renamed(session):
    """The secrets a session of a TLS 1.3 flow's first keys found that are newer than the first traffic secret they were
    named, named again by the least number of updates they can have come after, and kept apart, as Wireshark would try
    them from the start: a KeyUpdate sent padded shows by no size, so among the first records a newer secret opens one at
    sequence number 0 as the first does. The first secret of a client opens its second record, the one after its
    Finished, and that of a server comes before every record the server sent after the client's Finished arrived, since
    the client sends that only once it has the server's whole handshake. A client that sent early data has records
    before its Finished, which no order tells apart, and is left as it is."""
    if session.version != 0x0304 or session.quic or session.epochs or session.early or not getattr(session, "sides", None):
        return []
    (client, client_marks), (server, server_marks) = session.sides
    sent, _ = tlsrecords.updates(client, session.suite)
    got, _ = tlsrecords.updates(server, session.suite)
    finished = arrived(client_marks, sent[0][0] + 1) if sent else None
    out = []
    for hit in list(session.found.values()):
        if hit.label == "CLIENT_TRAFFIC_SECRET_0":
            later = hit.index > 1
        elif hit.label == "SERVER_TRAFFIC_SECRET_0" and finished is not None:
            later = any(arrived(server_marks, at + len(record)) > finished for at, record in got[: hit.index])
        else:
            continue
        if later:
            del session.found[hit.label]
            hit.label, hit.later = f"{hit.label.split('_')[0]}_TRAFFIC_SECRET_1", True
            session.found[hit.label] = hit
            out.append(hit)
    return out


def socket_of(live, flow):
    """The entry of the socket a flow went through among those of the guest: by its two ends, or, as a UDP socket is
    often bound to every address, by its port alone. flow is a Flow of follow or a flow of the capture."""
    proto, guest, remote = (flow.proto, flow.guest, flow.remote) if isinstance(flow, Flow) else (flow["proto"], flow["guest"], flow["remote"])
    port = guest.rsplit(":", 1)[-1]
    for entry in live:
        if entry["proto"] == proto and entry["local"] == guest and entry["remote"] in ("", remote):
            return entry
    for entry in live:
        if entry["proto"] == proto and entry["local"] in (f"0.0.0.0:{port}", f"[::]:{port}") and entry["remote"] in ("", remote):
            return entry
    return None


def owner(flow, live):
    """The process a flow belonged to: as owners saw it, or as the guest's memory shows it now."""
    matched = re.search(r"\[(\d+)\]$", flow.get("owner") or "")
    if matched:
        return int(matched.group(1))
    entry = socket_of(live, flow)
    return entry["pid"] if entry else None


def by_program(picked, named):
    """The flows by the program to search: its own when owners knew it, every one --process named otherwise."""
    by = {}
    for s in picked:
        for pid in [s.flow["pid"]] if s.flow.get("pid") is not None else named:
            by.setdefault(pid, []).append(s)
    return by


def linux(picked, args):
    """The flows of a guest that is not Windows by the process each belongs to, as the guest's agent names them, each
    process read through its page map."""
    if not os.environ.get("VM_INSPECT_DIR"):
        shared.fail("this needs an open session")
    ram = Physical()
    if args.process:
        named = [int(pid) for pid in args.process if pid.isdigit()]
        return [(Pagemap(ram, pid), group) for pid, group in by_program(picked, named).items()] or shared.fail(
            "in a guest that is not Windows --process takes process numbers for flows whose program is not known")
    live, by = owners.Agent().sample(), {}
    for s in picked:
        by.setdefault(owner(s.flow, live), []).append(s)
    for s in by.pop(None, []):
        print(f"{s.flow['id']}: its program is not known, owners --follow while it runs finds it, or --process names it", file=sys.stderr)
    return [(Pagemap(ram, pid), group) for pid, group in by.items()]


def run(capture, args, flows, chosen):
    scanner = Scanner(shared.SETTINGS.scan)
    if args.follow:
        Follower(capture, args, scanner, chosen).run()
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
        except (LookupError, OSError):
            memory = None
        if memory is None:
            groups = linux(picked, args)
        elif args.process:
            named = []
            for name in args.process:
                try:
                    named.append(memory.windows.pid(name))
                except LookupError as e:
                    print(f"guest-net: {e}", file=sys.stderr)
            groups = [(Process(memory.windows, pid), group) for pid, group in by_program(picked, named).items()]
        else:
            live, by = memory.sample(), {}
            for s in picked:
                by.setdefault(owner(s.flow, live), []).append(s)
            for s in by.pop(None, []):
                print(f"{s.flow['id']}: its program is not known, owners --follow while it runs finds it, or --process names it", file=sys.stderr)
            groups = [(Process(memory.windows, pid), group) for pid, group in by.items()]
    searched = {}
    for source, group in groups:
        for s in group:
            searched.setdefault(id(s), []).append(source)
        try:
            search(scanner, source, group, args)
        except LookupError as e:
            print(f"guest-net: {source}: {e}", file=sys.stderr)
    # A TLS 1.3 flow whose first secrets are gone may have updated its keys with KeyUpdates sent padded, which no record's size
    # tells, and a QUIC flow's updates show in no packet at all, so the newest secrets of both are looked for at the records
    # they may open, in what was searched for them before.
    covered = {s.flow["id"] for s in picked if s.epochs}
    retry = {s.flow["id"]: s for s in picked if not s.epochs and s.version == 0x0304 and not finished(s)
             and id(s) in searched and s.flow["id"] not in covered}
    again = {}
    retried = (newer_sessions(capture, args, [s for s in retry.values() if not s.quic], broad=True)
               + late_quic_sessions(capture, args, [s for s in retry.values() if s.quic]))
    for newer in retried:
        for source in searched[id(retry[newer.flow["id"]])]:
            again.setdefault(source, []).append(newer)
        picked.append(newer)
    for source, group in again.items():
        try:
            search(scanner, source, group, args)
        except LookupError as e:
            print(f"guest-net: {source}: {e}", file=sys.stderr)
    for late, newer in acknowledged_sessions(scanner, [s for s in retried if s.quic and not finished(s)]):
        for source in searched[id(retry[late.flow["id"]])]:
            try:
                search(scanner, source, [newer], args)
            except LookupError as e:
                print(f"guest-net: {source}: {e}", file=sys.stderr)
        late.found.update(newer.found)
    for s in picked:
        renamed(s)
    lines = [hit.line for s in picked for hit in s.found.values() if not (s.epochs or hit.later)]
    later = [hit.line for s in picked for hit in s.found.values() if s.epochs or hit.later]
    for at in range(0, len(lines), 4096):
        tell({"do": "note", "kind": "keys", "lines": lines[at: at + 4096]})
    # Wireshark takes only the first traffic secrets, so the newer ones go in a log of their own, which guest-net opens itself.
    for at in range(0, len(later), 4096):
        tell({"do": "note", "kind": "updated", "lines": later[at: at + 4096]})
    for s in picked:
        names = plain(",".join(s.flow["names"]) or s.flow["remote"], 60)
        kind = ("QUIC" if s.quic else "TLS " + VERSIONS[s.version]) + (" after key updates" if s.epochs else "")
        if s.found:
            where = ", ".join(f"{label} at {hit.address:#x}" for label, hit in sorted(s.found.items()))
            print(f"{s.flow['id']:<6} {names}  {kind}  {where}")
        else:
            print(f"{s.flow['id']:<6} {names}  {kind}  not found")
    print(f"{len(lines) + len(later)} secrets added to the capture", file=sys.stderr)


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
    """A flow whose memory was copied when its client began to encrypt, kept until its records tell the secrets. An early
    one was copied when the client sent early data, for the secret of that alone."""

    def __init__(self, flow, windows, whole, source, early=False):
        self.flow, self.windows, self.whole, self.source, self.early = flow, windows, whole, source, early
        self.since, self.told, self.records, self.searched = time.monotonic(), set(), 0, ""

    def wanted(self, found):
        return {"CLIENT_EARLY_TRAFFIC_SECRET"} if self.early else WANTED[found.version]


class Opening:
    """What a QUIC connection's first packets tell before the server answers: the client random and the name asked for."""

    def __init__(self, client_random, name):
        self.client_random, self.name = client_random, name


class Flow:
    """What follow knows of one connection: its two ends, and for TCP where each side's sequence numbers began and the bytes
    each sent first, for QUIC the datagrams of its first seconds, each with whether the guest sent it."""

    def __init__(self, guest, remote, proto="tcp"):
        self.guest, self.remote, self.proto, self.pieces, self.start = guest, remote, proto, ([], []), [None, None]
        self.datagrams, self.hellos, self.first = [], None, None
        # How many records the client had encrypted when the server's first encrypted record came.
        self.before = None
        self.trigger, self.early_trigger = time.time(), None

    def oriented(self):
        """The datagrams as from the client, 0, or the server, 1: the client is the side whose first datagram is an Initial."""
        guest_is_client = next((from_guest for from_guest, data in self.datagrams if data[:1] and data[0] & 0x80), True)
        return [(0 if from_guest == guest_is_client else 1, data) for from_guest, data in self.datagrams]

    def session(self, opener=None):
        if self.proto == "udp":
            if self.hellos is None and opener:
                self.hellos = tlsrecords.quic_hellos(self.oriented(), opener)
            return tlsrecords.quic_session(self.oriented(), *self.hellos) if self.hellos else None
        guest, other = (contiguous(side) for side in self.pieces)
        return tlsrecords.session(guest, other) or tlsrecords.session(other, guest)

    def __str__(self):
        return f"{self.guest} -> {self.remote}"


class Follower:
    """keys scan --follow: copies the memory of each new TLS flow's program as soon as its client sends its first encrypted
    record, when the secrets are surely there, and checks the copy as the flow's records come in. Flows that begin
    together are copied together, one read of each program, since a browser opens many at once and closes them soon."""

    PATIENCE = 30

    def __init__(self, capture, args, scanner, chosen):
        self.capture, self.args, self.scanner, self.chosen = capture, args, scanner, chosen
        self.flows, self.pending, self.handled, self.ready, self.later = {}, {}, set(), [], []
        # The process whose connection was seen last, and the flows put to it without a socket of their own.
        self.recent, self.guessed = None, set()
        # The processes whose parents the capture has been told of, for --children of the readers, and the QUIC connections
        # whose early data was copied for.
        self.listed, self.early = set(), set()
        self.memory = self.physical = self.pause = None
        if args.physical and chosen.processes:
            shared.fail("--process needs each program's own memory, which --physical does not read by program")
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

    def flow_of(self, stream):
        """A flow by its key, or by ("early", its key) for the copy taken for its early data."""
        return self.flows[stream[1]] if stream[0] == "early" else self.flows[stream]

    def trigger_of(self, stream):
        return self.flow_of(stream).early_trigger if stream[0] == "early" else self.flow_of(stream).trigger

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
        key, side = (packet.proto, packet.guest, packet.remote), 0 if packet.sent else 1
        if packet.proto == "udp":
            self.datagram(key, packet)
            return
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
            if not self.chosen.host([found.name] if found.name else [], flow.remote.rsplit(":", 1)[0]):
                return
            if self.scanner.supported(found):
                self.ready.append((key, found))
            else:
                print(f"{flow}: TLS {found.version:#06x} with suite {found.suite:#06x} is not one keys scan knows", file=sys.stderr)

    def datagram(self, key, packet):
        """Takes one datagram into its QUIC connection, and puts the connection up for copying once its client sends a packet
        with a short header, which it does only with its traffic secrets."""
        flow = self.flows.get(key)
        if flow is None:
            if key in self.handled:
                return
            data = packet.payload
            # Only a connection seen from its start is followed: its first datagram has a long header of a known version.
            if not (len(data) > 5 and data[0] & 0x80 and int.from_bytes(data[1:5], "big") in tlsrecords.QUIC_VERSIONS):
                self.handled.add(key)
                return
            flow = self.flows[key] = Flow(packet.guest, packet.remote, "udp")
            flow.first = packet.time
        if packet.time - flow.first <= QUIC_OPENING and len(flow.datagrams) < 400:
            flow.datagrams.append((packet.sent, packet.payload))
        if key not in self.early and packet.sent and any(kind == "early" for kind, *_ in tlsrecords.quic_packets(packet.payload, None)):
            # Early data goes out with the client's first packets, under a secret its library wipes once the handshake is done,
            # so its copy is taken now, from the client's hello alone, and checked once the server has answered.
            hello = tlsrecords.quic_client_hello(flow.oriented(), self.scanner.quic_initial)
            if hello:
                self.early.add(key)
                flow.early_trigger = packet.time
                if self.chosen.host([hello[1]] if hello[1] else [], flow.remote.rsplit(":", 1)[0]):
                    self.ready.append((("early", key), Opening(*hello)))
        if key in self.handled:
            return
        found = flow.session(self.scanner.quic_initial)
        if found and any(side == 0 and kind == tlsrecords.SHORT_PACKET for side, kind, _, _ in found.records):
            self.handled.add(key)
            flow.trigger = packet.time
            if not self.chosen.host([found.name] if found.name else [], flow.remote.rsplit(":", 1)[0]):
                return
            if self.scanner.supported(found):
                self.ready.append((key, found))
            else:
                print(f"{flow}: QUIC with suite {found.suite:#06x} is not one keys scan knows", file=sys.stderr)

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
        held, waited = time.monotonic(), time.time() - min(self.trigger_of(s) for _, members in groups for s, _ in members)
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
        # A flow without a socket was put to each program it may be of, and is that of the first whose memory has its client random.
        placed, missed = set(), {}
        for source, members, windows, whole in copies:
            print(f"guest-net: {len(members)} new flows of {source}, {sum(1 for w in windows.values() if w)} with their client random "
                  f"found{', all of its memory kept' if whole else ''}, copied {waited * 1000:.0f} ms after the handshake in {took_ms:.0f} ms",
                  file=sys.stderr)
            for stream, _ in members:
                if stream in self.guessed:
                    if not windows[stream] or stream in placed:
                        missed.setdefault(stream, []).append(str(source))
                        continue
                    placed.add(stream)
                self.pending[stream] = Pending(self.flow_of(stream), windows[stream], whole, source, early=stream[0] == "early")
        for stream, sources in missed.items():
            if stream not in placed:
                print(f"{self.flow_of(stream)}: no socket of it was seen, and its client random is in none of {', '.join(sources)}", file=sys.stderr)

    def owners(self, batch):
        """The flows of a batch by the process their connection belongs to, as the guest's memory shows it now, which is
        also kept in the capture, with the size of each process's writable memory, smallest first."""
        windows, by = self.memory.windows, {}
        live = self.memory.sample()
        # MemProcFS leaves out the connections of a process it does not know yet, as a program just started. Its list of UDP
        # sockets misses many of QUIC's anyway, so only TCP is worth the time this takes.
        if any(socket_of(live, self.flow_of(stream)) is None and self.flow_of(stream).proto == "tcp" for stream, _ in batch):
            windows.vmm.VMMDLL_ConfigSet(windows.handle, REFRESH_PROCESSES, 1)
            live = self.memory.sample()
        entries = {}

        def parent_of(child):
            try:
                parent = windows.information(child)[1]
                return parent, windows.information(parent)[0]
            except LookupError:
                return None, ""

        def wanted(pid, name=None):
            if name is None:
                try:
                    name = windows.information(pid)[0]
                except LookupError:
                    name = ""
            return self.chosen.covers(pid, name, parent_of)

        candidates = None
        for stream, found in batch:
            entry = entries[stream] = socket_of(live, self.flow_of(stream))
            if entry is None and self.flow_of(stream).proto == "udp":
                # A QUIC connection of a browser is its network process's like its others, and one of a program just started
                # is its own or a child's, which its client random proves.
                candidates = self.candidates(windows, wanted) if candidates is None else candidates
                if candidates:
                    self.guessed.add(stream)
                    for pid in candidates:
                        by.setdefault(pid, []).append((stream, found))
                continue
            if entry is None:
                late = (time.time() - self.trigger_of(stream)) * 1000
                port = self.flow_of(stream).guest.rsplit(":", 1)[-1]
                near = [f"{e['proto']} {e['local']} -> {e['remote'] or '*'} {e['process']}[{e['pid']}]" for e in live if e["local"].endswith(f":{port}")]
                print(f"{self.flow_of(stream)} {plain(found.name or '', 60)}: closed before its program was seen, {late:.0f} ms after its handshake"
                      f"{', its port has ' + '; '.join(near) if near else ''}", file=sys.stderr)
                continue
            # A program that was not asked for still counts as the last one seen, for the QUIC of a browser.
            self.recent = entry["pid"]
            if wanted(entry["pid"], entry["process"]):
                by.setdefault(entry["pid"], []).append((stream, found))
        if not by:
            return []
        seen = [entries[s] for group in by.values() for s, _ in group if entries[s]]
        if seen:
            tell({"do": "note", "kind": "owners", "entries": seen})
        started = [p for p in owners.lineage(windows, list(by)) if (p["pid"], p["ppid"], p["process"]) not in self.listed]
        if started:
            tell({"do": "note", "kind": "processes", "entries": started}, needed=False)
            self.listed |= {(p["pid"], p["ppid"], p["process"]) for p in started}
        windows.vmm.VMMDLL_ConfigSet(windows.handle, REFRESH_TLB, 1)
        groups = []
        for pid, members in by.items():
            source = Process(windows, pid)
            groups.append((source, members, sum(length for _, length in source.ranges())))
        return sorted(groups, key=lambda group: group[2])

    def candidates(self, windows, wanted):
        """The programs a QUIC flow without a socket may be of: those --process asked for that run now, newest last and four at
        most, and the one whose connection was seen last."""
        found = []
        if self.chosen.processes:
            windows.vmm.VMMDLL_ConfigSet(windows.handle, REFRESH_PROCESSES, 1)
            listed = {pid: (parent, name) for pid, parent, name in windows.processes()}

            def parent_of(child):
                parent = listed.get(child, (None, ""))[0]
                return (parent, listed[parent][1]) if parent in listed else (None, "")

            found = [pid for pid, (_, name) in listed.items() if self.chosen.covers(pid, name, parent_of)][-4:]
        if self.recent is not None and self.recent not in found and wanted(self.recent):
            found.append(self.recent)
        return found

    def check(self, pending, stream, final=False):
        """Tries the copy against the flow's records when more have come, and adds what opens them. Whether it is done."""
        found = pending.flow.session(self.scanner.quic_initial)
        if not found:
            return False
        wanted = pending.wanted(found)
        if len(found.records) == pending.records and not final:
            return wanted <= pending.told
        pending.records = len(found.records)
        hits = []
        for low, window in pending.windows:
            hits += self.scanner.scan(window, len(window), low, [found], step=1, threads=threads())
        labels = pending.told | {hit.label for hit in hits}
        # The whole copy is searched once, when the records the traffic secrets open have come.
        ready = final or found.version != 0x0304 or sum(1 for record in found.records if record[0] == 1) > 1
        if not wanted <= labels and pending.whole and ready:
            total = sum(length for _, _, length in pending.whole)
            step = step_for(self.args, total)
            for start, buffer, length in pending.whole:
                hits += self.scanner.scan(buffer, length, start, [found], step=step, threads=threads())
            pending.whole, pending.searched = None, f", {size(total)} searched at step {step}"
        fresh = {hit.label: hit for hit in hits if hit.label not in pending.told}
        if fresh:
            tell({"do": "note", "kind": "keys", "lines": [hit.line for hit in fresh.values()]})
            # A flow put to a program without a socket of its own is that program's once its memory opened the flow, which
            # the readers' --process and their owners column learn only from the capture.
            if stream in self.guessed and isinstance(pending.source, Process):
                self.guessed.discard(stream)
                tell({"do": "note", "kind": "owners", "entries": [{"proto": pending.flow.proto, "local": pending.flow.guest, "remote": pending.flow.remote,
                                                                    "pid": pending.source.pid, "process": plain(pending.source.name, 200), "source": "keys"}]})
            pending.told |= set(fresh)
            print(f"{pending.flow}  {plain(found.name or '-', 60)}  {'QUIC' if found.quic else 'TLS ' + VERSIONS[found.version]}  "
                  f"{', '.join(sorted(fresh))} in {pending.source}")
            sys.stdout.flush()
        done = wanted <= pending.told
        if done:
            del self.pending[stream]
        return done

    def expire(self, final=False):
        """Lets go of flows that have waited long enough for their records, saying of those without secrets."""
        for stream, pending in list(self.pending.items()):
            late = final or time.monotonic() - pending.since > self.PATIENCE
            if late and not self.check(pending, stream, final=True):
                found = pending.flow.session(self.scanner.quic_initial)
                counts = [sum(1 for record in found.records if record[0] == side) for side in (0, 1)] if found else [0, 0]
                # A client that sent only its Finished has nothing its traffic secret could open, nor anything to decrypt.
                if pending.told == {"SERVER_TRAFFIC_SECRET_0"} and counts[0] <= 1:
                    self.pending.pop(stream, None)
                    continue
                print(f"{pending.flow} {plain(getattr(found, 'name', '') or '-', 60)}: "
                      f"{'only ' + ', '.join(sorted(pending.told)) if pending.told else 'its early data secret was not in the copy' if pending.early else 'its secrets were not in the copy'} "
                      f"({len(pending.windows)} places of its client random{pending.searched}, {counts[0]} records of the client and "
                      f"{counts[1]} of the server{', early data offered' if getattr(found, 'early', False) else ''})", file=sys.stderr)
                self.pending.pop(stream, None)

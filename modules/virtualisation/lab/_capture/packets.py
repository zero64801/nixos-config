"""The TCP payloads of a capture as it grows, read straight from its pcapng blocks, for keys scan --follow, which has to
act within a few milliseconds of a handshake and so cannot wait on tshark. The frames are the guest's, so every length is
checked before it is used and anything that does not parse is passed over."""
import ipaddress
import os
import struct

INTERFACE, ENHANCED_PACKET = 1, 6
ETHERNET, IPV4, IPV6, VLAN, TCP = 1, 0x0800, 0x86DD, 0x8100, 6
SYN = 0x02
# epb_flags, whose two lowest bits are the direction: 2 for what the guest sent.
FLAGS, OUTBOUND = 2, 2
# if_tsresol, a power of ten when its top bit is clear.
RESOLUTION = 9


class Packet:
    __slots__ = ("guest", "payload", "remote", "sent", "seq", "syn", "time")

    def __init__(self, time, sent, guest, remote, seq, payload, syn):
        self.time, self.sent, self.guest, self.remote, self.seq, self.payload, self.syn = time, sent, guest, remote, seq, payload, syn


def endpoint(address, port):
    return f"[{address}]:{port}" if ":" in address else f"{address}:{port}"


def ipv4(raw):
    return ".".join(str(b) for b in raw)


def ipv6(raw):
    return ipaddress.IPv6Address(raw).compressed


def options(body, at):
    """The options of a block from this offset, as {code: value}."""
    found = {}
    while at + 4 <= len(body):
        code, length = struct.unpack_from("<HH", body, at)
        if code == 0:
            break
        found[code] = body[at + 4: at + 4 + length]
        at += 4 + length + (-length % 4)
    return found


class Reader:
    """Reads the blocks a capture has gained since the last call, from where tail() left off."""

    def __init__(self, path, head, start):
        self.descriptor, self.offset = os.open(path, os.O_RDONLY | os.O_CLOEXEC), start
        self.rest, self.interfaces = b"", []
        at = 0
        while at + 12 <= len(head):
            kind, length = struct.unpack_from("<II", head, at)
            if length < 12 or at + length > len(head):
                break
            if kind == INTERFACE and length >= 20:
                linktype = struct.unpack_from("<H", head, at + 8)[0]
                resolution = options(head[at + 16: at + length - 4], 0).get(RESOLUTION, b"\x06")[:1]
                scale = 10 ** resolution[0] if resolution and resolution[0] < 0x80 else 10 ** 6
                self.interfaces.append((linktype, scale))
            at += length

    def close(self):
        os.close(self.descriptor)

    def poll(self):
        """The TCP packets with a payload, or a SYN, in the blocks written since the last call."""
        more = os.pread(self.descriptor, 1 << 22, self.offset)
        self.offset += len(more)
        data = self.rest + more
        found, at = [], 0
        while at + 12 <= len(data):
            kind, length = struct.unpack_from("<II", data, at)
            if length < 12 or length % 4:
                # Not a block boundary, which a capture written by the session never has.
                data, at = b"", 0
                break
            if at + length > len(data):
                break
            if kind == ENHANCED_PACKET:
                packet = self.packet(data, at + 8, at + length - 4)
                if packet:
                    found.append(packet)
            at += length
        self.rest = data[at:]
        return found

    def packet(self, data, start, end):
        if end - start < 20:
            return None
        interface, high, low, caught, _ = struct.unpack_from("<IIIII", data, start)
        if interface >= len(self.interfaces) or start + 20 + caught > end:
            return None
        linktype, scale = self.interfaces[interface]
        frame = data[start + 20: start + 20 + caught]
        flags = options(data[start + 20 + caught + (-caught % 4): end], 0).get(FLAGS, b"")
        sent = len(flags) == 4 and struct.unpack("<I", flags)[0] & 3 == OUTBOUND
        if linktype != ETHERNET:
            return None
        return parse(frame, ((high << 32) | low) / scale, sent)


def parse(frame, when, sent):
    """A TCP packet of an Ethernet frame, or None."""
    if len(frame) < 14:
        return None
    at, kind = 14, struct.unpack_from(">H", frame, 12)[0]
    while kind == VLAN and len(frame) >= at + 4:
        kind, at = struct.unpack_from(">H", frame, at + 2)[0], at + 4
    if kind == IPV4 and len(frame) >= at + 20:
        header = (frame[at] & 0x0F) * 4
        total = struct.unpack_from(">H", frame, at + 2)[0]
        fragment = struct.unpack_from(">H", frame, at + 6)[0] & 0x3FFF
        if frame[at + 9] != TCP or header < 20 or fragment:
            return None
        source, target, end = ipv4(frame[at + 12: at + 16]), ipv4(frame[at + 16: at + 20]), min(len(frame), at + total)
        at += header
    elif kind == IPV6 and len(frame) >= at + 40:
        if frame[at + 6] != TCP:
            return None
        source, target = ipv6(frame[at + 8: at + 24]), ipv6(frame[at + 24: at + 40])
        end = min(len(frame), at + 40 + struct.unpack_from(">H", frame, at + 4)[0])
        at += 40
    else:
        return None
    if end < at + 20:
        return None
    ports, seq, _, offset, flags = struct.unpack_from(">4sIIBB", frame, at)
    header = (offset >> 4) * 4
    if header < 20 or at + header > end:
        return None
    here, there = struct.unpack(">HH", ports)
    ours, theirs = (endpoint(source, here), endpoint(target, there)) if sent else (endpoint(target, there), endpoint(source, here))
    return Packet(when, sent, ours, theirs, seq, frame[at + header: end], bool(flags & SYN))


def follow(path):
    """Opens a capture to read it from its present end on."""
    head, at = b"", 0
    with open(path, "rb") as f:
        end = os.fstat(f.fileno()).st_size
        while at + 8 <= end:
            f.seek(at)
            kind, length = struct.unpack("<II", f.read(8))
            if length < 12 or at + length > end:
                break
            if kind != ENHANCED_PACKET and at == len(head):
                f.seek(at)
                head += f.read(length)
            at += length
    return Reader(path, head, at)

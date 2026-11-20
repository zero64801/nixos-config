"""A capture of its own for what guest-net opened itself, the flows of TLS 1.3 after key updates, written as plain TCP with
the flows' own addresses and times, so that tshark reads its HTTP as it reads any. A flow of HTTP/1 goes to port 80, one
of HTTP/2 to port 2443, which tshark is told to read as HTTP/2. The guest's port stays its own, which ties each flow
back to the capture it came from."""
import ipaddress
import json
import os
import struct

HTTP2_PORT = 2443
OPTIONS = ["-d", f"tcp.port=={HTTP2_PORT},http2"]
# A segment of TCP no larger than an IP packet of either version can carry.
SEGMENT = 32768
METHODS = (b"GET ", b"POST ", b"PUT ", b"HEAD ", b"DELETE ", b"PATCH ", b"OPTIONS ", b"CONNECT ", b"TRACE ")


def kind(chunks):
    """http for HTTP/1, which begins with a method or a status line, http2 otherwise."""
    for _, from_guest, data in chunks:
        if (from_guest and data.startswith(METHODS)) or (not from_guest and data.startswith(b"HTTP/1.")):
            return "http"
    return "http2"


def block(code, body):
    body += bytes(-len(body) % 4)
    return struct.pack("<II", code, len(body) + 12) + body + struct.pack("<I", len(body) + 12)


def option(code, value):
    return struct.pack("<HH", code, len(value)) + value + bytes(-len(value) % 4)


def checksum(header):
    total = sum(struct.unpack(f"!{len(header) // 2}H", header))
    while total >> 16:
        total = (total >> 16) + (total & 0xFFFF)
    return ~total & 0xFFFF


def split(endpoint):
    address, _, port = endpoint.rpartition(":")
    return ipaddress.ip_address(address.strip("[]")), int(port)


class Flow:
    """One flow as packets: its handshake of TCP, then each chunk in segments, each side's sequence numbers its own."""

    def __init__(self, guest, remote, port, number):
        (self.guest, self.guest_port), (self.remote, _) = split(guest), split(remote)
        self.remote_port, self.number, self.seq, self.packets = port, number, [1000, 5000], []

    def packet(self, when, from_guest, flags, payload=b""):
        side = 0 if from_guest else 1
        ends = (self.guest, self.remote) if from_guest else (self.remote, self.guest)
        ports = (self.guest_port, self.remote_port) if from_guest else (self.remote_port, self.guest_port)
        tcp = struct.pack("!HHIIBBHHH", *ports, self.seq[side], self.seq[1 - side], 5 << 4, flags, 65535, 0, 0) + payload
        if ends[0].version == 4:
            ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(tcp), self.number & 0xFFFF, 0, 64, 6, 0, ends[0].packed, ends[1].packed))
            ip[10:12] = struct.pack("!H", checksum(bytes(ip)))
        else:
            ip = struct.pack("!IHBB16s16s", 6 << 28, len(tcp), 6, 64, ends[0].packed, ends[1].packed)
        self.packets.append((when, from_guest, bytes(ip) + tcp))
        self.seq[side] += len(payload) + (1 if flags & 0x02 else 0)

    def made(self, chunks):
        begun = chunks[0][0] - 0.001
        self.packet(begun, True, 0x02)
        self.packet(begun, False, 0x12)
        self.packet(begun, True, 0x10)
        for when, from_guest, data in chunks:
            for at in range(0, len(data), SEGMENT):
                self.packet(when, from_guest, 0x18, data[at: at + SEGMENT])
        return self.packets


def write(folder, started, flows):
    """Writes the capture into the folder: net.pcapng of the flows, each (guest endpoint, remote endpoint, chunks), and a
    capture.json that says when the capture it came from began."""
    packets = []
    for number, (guest, remote, chunks) in enumerate(flows):
        if chunks:
            port = 80 if kind(chunks) == "http" else HTTP2_PORT
            packets += Flow(guest, remote, port, number).made(sorted(chunks, key=lambda chunk: chunk[0]))
    packets.sort(key=lambda packet: packet[0])
    with open(os.path.join(folder, "net.pcapng"), "wb") as f:
        f.write(block(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1)))
        f.write(block(1, struct.pack("<HHI", 101, 0, 65535) + option(9, b"\x09") + option(0, b"")))
        for when, from_guest, data in packets:
            nanoseconds = int(when * 1e9)
            f.write(block(6, struct.pack("<IIIII", 0, nanoseconds >> 32, nanoseconds & 0xFFFFFFFF, len(data), len(data)) + data
                          + bytes(-len(data) % 4) + option(2, struct.pack("<I", 2 if from_guest else 1)) + option(0, b"")))
    with open(os.path.join(folder, "capture.json"), "w") as f:
        json.dump({"started": started, "net": [{"name": "opened by guest-net", "mac": "-"}]}, f)

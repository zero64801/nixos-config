"""keys scan's whole one look on a capture, with made up memory in place of the guest's RAM. aioquic's client downloads
through a relay that loses every fifth of the server's datagrams before it keeps them, then updates its keys and asks once
more, and only the secrets after the update are in the memory. The first keys are not found, the pass after it finds
the client's newer secret from the last packets, and the search after that the server's, at the numbers the client
acknowledged. Both have to reach the capture as updated keys, and guest-net has to read what was asked after the update
with them.

usage: scan_run_logic.py CAPTURE_CODE TSHARK_FOLDER LIBTLSSCAN"""
import argparse
import asyncio
import base64
import contextlib
import io
import json
import os
import re
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time

from aioquic.asyncio import connect, serve
from aioquic.quic.configuration import QuicConfiguration

code, wireshark, library = sys.argv[1:4]
sys.path.insert(0, code)
import capture
import net
import scan

subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "key.pem",
                "-out", "cert.pem", "-days", "1", "-subj", "/CN=localhost"], check=True, capture_output=True)


class Relay:
    """Passes the datagrams of one client on to the server and keeps each, in order, with whether the client sent it and
    when, but loses every fifth of the server's after its first ones on the way, before it keeps them."""

    def __init__(self, server):
        self.client, self.kept, self.count = None, [], 0
        self.outside = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.outside.bind(("127.0.0.1", 0))
        self.port = self.outside.getsockname()[1]
        self.inside = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.inside.connect(("127.0.0.1", server))
        threading.Thread(target=self.up, daemon=True).start()
        threading.Thread(target=self.down, daemon=True).start()

    def up(self):
        while True:
            data, self.client = self.outside.recvfrom(65536)
            self.kept.append((True, time.time(), data))
            self.inside.send(data)

    def down(self):
        while True:
            data = self.inside.recv(65536)
            self.count += 1
            if self.count > 25 and self.count % 5 == 0:
                continue
            self.kept.append((False, time.time(), data))
            if self.client:
                self.outside.sendto(data, self.client)


async def handle(reader, writer):
    asked = await reader.read()
    writer.write(b"y" * 1_000_000 if asked == b"big" else b"answer to " + asked)
    writer.write_eof()


async def ask(client, question):
    reader, writer = await client.create_stream()
    writer.write(question)
    writer.write_eof()
    return await reader.read()


async def talk(keys):
    configuration = QuicConfiguration(alpn_protocols=["test"], is_client=False)
    configuration.load_cert_chain("cert.pem", "key.pem")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    listener = await serve("127.0.0.1", port, configuration=configuration, stream_handler=lambda reader, writer: asyncio.ensure_future(handle(reader, writer)))
    relay = Relay(port)
    client_configuration = QuicConfiguration(alpn_protocols=["test"], is_client=True, verify_mode=ssl.CERT_NONE, secrets_log_file=keys)
    async with connect("127.0.0.1", relay.port, configuration=client_configuration) as client:
        assert len(await ask(client, b"big")) == 1_000_000
        client._quic.request_key_update()
        client.transmit()
        assert await ask(client, b"after") == b"answer to after"
        await asyncio.sleep(0.2)
    listener.close()
    return relay.kept


with open("keys.log", "w") as keys:
    kept = asyncio.run(talk(keys))
with open("keys.log") as f:
    logged = {label: (random, bytes.fromhex(secret)) for label, random, secret in (line.split() for line in f if line.strip() and not line.startswith("#"))}


def option(kind, value):
    return struct.pack("<HH", kind, len(value)) + value + bytes(-len(value) % 4)


def block(kind, body):
    body += bytes(-len(body) % 4)
    return struct.pack("<II", kind, len(body) + 12) + body + struct.pack("<I", len(body) + 12)


def checksum(header):
    total = sum(struct.unpack("!10H", header))
    total = (total >> 16) + (total & 0xFFFF)
    return ~(total + (total >> 16)) & 0xFFFF


# As the session writes it: nanosecond times, and each frame's direction seen from the guest, which is the client here.
os.makedirs("capture", exist_ok=True)
with open("capture/net.pcapng", "wb") as f:
    f.write(block(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1)))
    f.write(block(1, struct.pack("<HHI", 101, 0, 65535) + option(9, b"\x09") + option(0, b"")))
    for number, (sent, stamp, data) in enumerate(kept):
        ends = (b"\x0a\x09\x09\x32", b"\x0a\x09\x09\x01") if sent else (b"\x0a\x09\x09\x01", b"\x0a\x09\x09\x32")
        ports = (40000, 443) if sent else (443, 40000)
        udp = struct.pack("!HHHH", *ports, 8 + len(data), 0) + data
        header = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), number & 0xFFFF, 0, 64, 17, 0, *ends))
        header[10:12] = struct.pack("!H", checksum(bytes(header)))
        frame = bytes(header) + udp
        nanoseconds = int(stamp * 1e9)
        f.write(block(6, struct.pack("<IIIII", 0, nanoseconds >> 32, nanoseconds & 0xFFFFFFFF, len(frame), len(frame)) + frame
                      + bytes(-len(frame) % 4) + option(2, struct.pack("<I", 2 if sent else 1)) + option(0, b"")))
with open("capture/capture.json", "w") as f:
    json.dump({"started": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(kept[0][1] - 1)), "net": [{"name": "relay", "mac": "-"}]}, f)

# lab-box is the lab's, and here everything runs in the build's sandbox already.
with open("box", "w") as f:
    f.write('#!/bin/sh\nwhile [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n')
os.chmod("box", 0o755)
capture.SETTINGS = capture.Settings("net", wireshark, os.path.abspath("box"), "-", "-", "-", library, "-")
recorded = capture.Capture("capture")

scanner = scan.Scanner(library)
suite = next(iter(scan.quic_hellos(recorded).values()))["suite"]
random = logged["CLIENT_TRAFFIC_SECRET_0"][0]
newest = {role: scanner.quic_next(1, suite, logged[f"{role}_TRAFFIC_SECRET_0"][1]) for role in ("CLIENT", "SERVER")}
memory = bytearray(os.urandom(1 << 18))
memory[8192: 8192 + len(newest["CLIENT"])] = newest["CLIENT"]
memory[200000: 200000 + len(newest["SERVER"])] = newest["SERVER"]
BASE = 0x40000000


class Ram:
    """The made up memory, where --physical reads the guest's RAM."""

    def __str__(self):
        return "the made up RAM"

    def regions(self, budget):
        return [(BASE, memory, len(memory))]


noted = []
scan.Physical, scan.tell = Ram, lambda request, needed=True: noted.append(request)
args = argparse.Namespace(follow=False, physical=True, process=None, deep=True, again=False, flow=None, max_memory=64, around=4096, step=8,
                          since=None, until=None)
with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as told:
    scan.run(recorded, args, net.flows(recorded, None), None)
said = out.getvalue()
print(told.getvalue() + said, end="")
# The first keys, the last packets of both sides, and the server's again at the numbers the client acknowledged.
assert told.getvalue().count("to search for 1 flows") == 3, told.getvalue()
assert re.search(r"u0 .* QUIC  not found", said), said
assert re.search(rf"u0 .* QUIC after key updates  CLIENT_TRAFFIC_SECRET_1 at {BASE + 8192:#x}, SERVER_TRAFFIC_SECRET_1 at {BASE + 200000:#x}", said), said
updated = [line for note in noted if note["kind"] == "updated" for line in note["lines"]]
assert sorted(updated) == sorted(f"{role}_TRAFFIC_SECRET_1 {random} {secret.hex()}" for role, secret in newest.items()), updated
assert not [line for note in noted if note["kind"] == "keys" for line in note["lines"]], noted
print("keys scan finds a QUIC flow's secrets after its update, the server's at the numbers the client acknowledged, and notes them apart")

# The session keeps what keys scan notes, and guest-net reads the flow with it.
with open("capture/updated.log", "w") as f:
    f.writelines(line + "\n" for line in updated)
got = {base64.b64decode(event[5]) for connection in net.quic_streams(recorded, None, "") for event in connection["events"]}
assert {b"after", b"answer to after"} <= got, got
with contextlib.redirect_stdout(io.StringIO()) as out:
    net.tls(recorded, argparse.Namespace(since=None, until=None, keys=None, process=None, children=False, host=None, max=100))
assert "decrypted from its key updates on, by guest-net" in out.getvalue(), out.getvalue()
print("guest-net reads what was asked after the update with what keys scan noted")

"""guest-net's reading of HTTP/3: curl asks aioquic's server several things over one QUIC connection, a relay keeps every
datagram, and they are written as a session writes its capture. With only the traffic secrets, which is all keys scan
needs to find, every request has to be listed and shown in full, headers that use QPACK's table among them. h3.py on its
own then has to wait for table instructions that come after the headers that need them, put pieces that come out of
order or twice back together, and live through what a hostile guest sends.

The server updates its keys before its first answer. With only the secrets after that update, which is all a program
holds once it updated them, guest-net has to open the rest of the connection itself and list what was asked there.

usage: h3_logic.py CAPTURE_CODE TSHARK_FOLDER CURL LIBTLSSCAN"""
import argparse
import asyncio
import base64
import contextlib
import io
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time

import pylsqpack
from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration

code, wireshark, curl, library = sys.argv[1:5]
sys.path.insert(0, code)
import capture
import net
import scan

subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "key.pem",
                "-out", "cert.pem", "-days", "1", "-subj", "/CN=localhost"], check=True, capture_output=True)
kept = []


class Relay:
    """Passes the datagrams of one client on to the server and keeps each, in order, with whether the client sent it."""

    def __init__(self, server):
        self.client = None
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
            kept.append((True, time.time(), data))
            self.inside.send(data)

    def down(self):
        while True:
            data = self.inside.recv(65536)
            kept.append((False, time.time(), data))
            if self.client:
                self.outside.sendto(data, self.client)


class Server(QuicConnectionProtocol):
    """Answers each request with its path, its method and what it was sent, as JSON, with a header of its own."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.h3, self.asked, self.bodies = None, {}, {}

    def quic_event_received(self, event):
        if self.h3 is None:
            self.h3 = H3Connection(self._quic)
        for e in self.h3.handle_event(event):
            if isinstance(e, HeadersReceived):
                self.asked[e.stream_id] = dict(e.headers)
            elif isinstance(e, DataReceived):
                self.bodies[e.stream_id] = self.bodies.get(e.stream_id, b"") + e.data
            if isinstance(e, (HeadersReceived, DataReceived)) and e.stream_ended:
                asked = self.asked[e.stream_id]
                body = json.dumps({"path": asked[b":path"].decode(), "method": asked[b":method"].decode(),
                                   "got": self.bodies.get(e.stream_id, b"").decode()}).encode()
                if asked[b":path"] == b"/first":
                    self._quic.request_key_update()
                self.h3.send_headers(e.stream_id, [(b":status", b"200"), (b"content-type", b"application/json"), (b"x-answered", b"by aioquic")])
                self.h3.send_data(e.stream_id, body, end_stream=True)
                self.transmit()


async def talk():
    configuration = QuicConfiguration(alpn_protocols=H3_ALPN, is_client=False)
    configuration.load_cert_chain("cert.pem", "key.pem")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    listener = await serve("127.0.0.1", port, configuration=configuration, create_protocol=Server)
    relay = Relay(port)
    base = f"https://localhost:{relay.port}"
    # The same headers again and again, so that the client's encoder puts them in its table.
    process = await asyncio.create_subprocess_exec(
        curl, "-sk", "--http3-only", "--max-time", "5", "-H", "x-asked: by curl", f"{base}/first", f"{base}/second", f"{base}/third",
        "--next", "-sk", "--http3-only", "--max-time", "5", "-H", "x-asked: by curl", "--data", "name=alice&pin=1234", f"{base}/form",
        env=dict(os.environ, SSLKEYLOGFILE="keys.full"), stdout=subprocess.PIPE)
    said, _ = await process.communicate()
    listener.close()
    return said


said = asyncio.run(talk())
assert said.count(b'"method": "GET"') == 3 and b'"got": "name=alice&pin=1234"' in said, said


def option(code, value):
    return struct.pack("<HH", code, len(value)) + value + bytes(-len(value) % 4)


def block(kind, body):
    body += bytes(-len(body) % 4)
    return struct.pack("<II", kind, len(body) + 12) + body + struct.pack("<I", len(body) + 12)


def checksum(header):
    total = sum(struct.unpack("!10H", header))
    total = (total >> 16) + (total & 0xFFFF)
    return ~(total + (total >> 16)) & 0xFFFF


# As the session writes it: nanosecond times, and each frame's direction seen from the guest, which is curl here.
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
started = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(kept[0][1] - 1))
with open("capture/capture.json", "w") as f:
    json.dump({"started": started, "net": [{"name": "relay", "mac": "-"}]}, f)
# Only the traffic secrets, which is what keys scan finds and what tshark cannot read HTTP/3 with.
with open("keys.full") as f, open("capture/keys.log", "w") as out:
    out.writelines(line for line in f if line.startswith(("CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0")))

# lab-box is the lab's, and here everything runs in the build's sandbox already.
with open("box", "w") as f:
    f.write('#!/bin/sh\nwhile [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n')
os.chmod("box", 0o755)
capture.SETTINGS = capture.Settings("net", wireshark, os.path.abspath("box"), "-", "-", "-", library, "-")
recorded = capture.Capture("capture")
args = argparse.Namespace(since=None, until=None, keys=None, process=None, children=False, host=None, id=None, max=300, body=4000, save=None,
                          request=False)
tshark_alone = subprocess.run([f"{wireshark}/tshark", "-n", "-r", "capture/net.pcapng", "-o", "tls.keylog_file:capture/keys.log", "-Y", "http3"],
                              capture_output=True, text=True, check=True).stdout
assert not tshark_alone.strip(), "tshark read HTTP/3 with the traffic secrets alone, so this test no longer tests what it should"

found = net.exchanges(recorded, args)
listed = [(r["method"], r["url"].rsplit("/", 1)[1], r["status"], r["type"], r["version"]) for r in found]
assert listed == [("GET", "first", "200", "application/json", "3"), ("GET", "second", "200", "application/json", "3"),
                  ("GET", "third", "200", "application/json", "3"), ("POST", "form", "200", "application/json", "3")], listed
assert all(r["took"] is not None and 0 <= r["took"] < 5 and r["flow"].startswith("u") for r in found), found
print("the requests of HTTP/3 are listed from the traffic secrets alone")


def shown(**changes):
    with contextlib.redirect_stdout(io.StringIO()) as out:
        net.http(recorded, argparse.Namespace(**{**vars(args), **changes}))
    return out.getvalue()


listing = shown()
assert "GET https://localhost:" in listing and "/third -> 200" in listing and " ms application/json" in listing, listing
form = shown(id=found[3]["id"])
assert "x-asked: by curl" in form and "request body:" in form and "name=alice&pin=1234" in form, form
assert "x-answered: by aioquic" in form and '"got": "name=alice&pin=1234"' in form, form
third = shown(id=found[2]["id"])
assert "x-asked: by curl" in third and '"path": "/third"' in third, "the third request's headers are only readable with the table"
print("one request of HTTP/3 is shown in full, headers and bodies both ways")


def decoded(connections):
    done = subprocess.run([sys.executable, "-I", "-B", os.path.join(code, "h3.py")], input=json.dumps({"connections": connections}).encode(),
                          capture_output=True, check=True)
    return json.loads(done.stdout)


def frame(kind, payload):
    return bytes([kind, len(payload)]) if len(payload) < 64 else bytes([kind, 0x40 | len(payload) >> 8, len(payload) & 0xFF])


def h3frame(kind, payload):
    length = len(payload)
    return bytes([kind]) + (bytes([length]) if length < 64 else bytes([0x40 | length >> 8, length & 0xFF])) + payload


def chunk(when, side, stream, offset, data, fin=False):
    return [when, when, side, stream, offset, base64.b64encode(data).decode(), fin]


# Each side allows the other a table, and the client's encoder fills its own with what it sends.
settings = h3frame(0x04, bytes([0x01, 0x50, 0x00, 0x07, 0x10]))
encoder = pylsqpack.Encoder()
encoder.apply_settings(4096, 16)
asked = [(b":method", b"GET"), (b":scheme", b"https"), (b":authority", b"late.test"), (b":path", b"/late"),
         (b"x-long-header-for-the-table", b"a value long enough to be worth a table entry")]
# ls-qpack puts headers in its table the second time it meets them.
encoder.encode(0, asked)
instructions, headers = encoder.encode(4, asked)
assert instructions and headers[0], "the encoder put nothing in its table, so nothing could wait on it"
answer = pylsqpack.Encoder()
answer.apply_settings(0, 0)
_, status = answer.encode(0, [(b":status", b"204")])
request = h3frame(0x01, headers)
events = [
    chunk(1, 0, 2, 0, b"\x00" + settings),
    chunk(2, 1, 3, 0, b"\x00" + settings),
    # The request comes in two pieces, the second first and once more, and before the table instructions it needs.
    chunk(3, 0, 4, 5, request[5:]),
    chunk(4, 0, 4, 0, request[:5]),
    chunk(5, 0, 4, 5, request[5:]),
    chunk(6, 0, 6, 0, b"\x02" + instructions),
    chunk(7, 1, 4, 0, h3frame(0x01, status), True),
]
late = decoded([{"flow": "u9", "events": events}])
assert [(r["method"], r["url"]) for r in late["requests"]] == [("GET", "https://late.test/late")], late
assert ["x-long-header-for-the-table", "a value long enough to be worth a table entry"] in late["requests"][0]["request_headers"], late
assert dict(map(tuple, late["requests"][0]["headers"]))[":status"] == "204" and not late["notes"], late
print("headers that wait on the table are read once its instructions come, pieces out of order and twice put together")

hostile = [
    chunk(1, 0, 0, 0, b"\x01\x3f" + b"\xff" * 63),
    chunk(2, 0, 4, 0, b"\xff" * 9 + b"\x01"),
    chunk(3, 0, 2, 0, b"\x02" + os.urandom(300)),
    chunk(4, 0, 8, 0, h3frame(0x01, os.urandom(40))),
    chunk(5, 1, 3, 0, b"\x00\x04\x08" + b"\xc0" * 8),
    chunk(6, 0, 12, 1 << 40, b"far"),
    chunk(7, 0, 16, 0, b"\x00\xbf\xff\xff\xff\xff\xff\xff\xff"),
]
survived = decoded([{"flow": "u1", "events": hostile}])
assert survived["requests"] == [] and len(survived["notes"]) >= 1, survived
print("what a hostile guest sends breaks nothing")


class Answered:
    """tshark's JSON of a connection whose client sent its first request as early data: the first data on a stream of even
    number the keys open is the server's answer, then the client's own control stream."""
    folder = "."

    def keylog(self, keys):
        return "keys"

    def output(self, file, arguments, keys=None):
        def packet(number, direction, frames):
            return {"_source": {"layers": {"frame": {"frame.number": str(number), "frame.time_epoch": "2026-11-20T00:14:45.5Z",
                                                     "frame.packet_flags": direction}, "udp": {"udp.stream": "7"},
                                           "quic": {"quic.frame": frames}}}}

        def stream(number, data, offset=0):
            return {"quic.stream.stream_id": str(number), "quic.stream.offset": str(offset), "quic.stream_data": data.hex(":"),
                    "quic.frame_type_tree": {"quic.stream.fin": "0"}}

        return json.dumps([packet(1, "0x00000001", [stream(0, b"\x01\x03\x00\x00\xd9")]),
                           packet(2, "0x00000002", [stream(2, b"\x00\x04\x00", 56)])])


chunks = net.quic_streams(Answered(), None, "")[0]["events"]
assert [(number, side, stream) for _, number, side, stream, *_ in chunks] == [(1, 1, 0), (2, 0, 2)], chunks
print("the sides of a connection are told apart by its unidirectional streams, though its first requests went as early data")

# A client that sent its settings and its request as early data: only the server's table instructions and its answer
# are there, and the table's size has to come from the server's first instruction.
server = pylsqpack.Encoder()
sized = server.apply_settings(65536, 100)
answered = [(b":status", b"200"), (b"content-type", b"text/html; charset=UTF-8"), (b"x-long-server-header", b"repeated often enough to be kept")]
server.encode(0, answered)
filled, block = server.encode(4, answered)
assert sized and filled and block[0], "the server's encoder used no table, so nothing here needs its size"
early = decoded([{"flow": "u3", "events": [chunk(1, 1, 3, 0, b"\x02" + sized + filled), chunk(2, 1, 4, 0, h3frame(0x01, block) + h3frame(0x00, b"<html>"), True)]}])
assert [(r["url"], dict(map(tuple, r["headers"])).get(":status"), base64.b64decode(r["body"])) for r in early["requests"]] == [
    ("(asked in early data)", "200", b"<html>")], early
assert not early["notes"], early
print("an answer whose request went as early data reads, its table sized by the server's first instruction")

# The answer's trailers, where gRPC puts its status, belong to the answer, not to the request.
plainly = pylsqpack.Encoder()
plainly.apply_settings(0, 0)
_, asked_block = plainly.encode(0, [(b":method", b"POST"), (b":scheme", b"https"), (b":authority", b"api.test"), (b":path", b"/demo.Greeter/Hello")])
_, status_block = plainly.encode(0, [(b":status", b"200")])
_, trailer_block = plainly.encode(0, [(b"grpc-status", b"0")])
call = decoded([{"flow": "u4", "events": [chunk(1, 0, 0, 0, h3frame(0x01, asked_block), True),
                                          chunk(2, 1, 0, 0, h3frame(0x01, status_block) + h3frame(0x00, b"x") + h3frame(0x01, trailer_block), True)]}])
answered_call = call["requests"][0]
assert answered_call["trailers"] == [["grpc-status", "0"]] and answered_call["request_trailers"] == [], answered_call
print("an answer's trailers stay with the answer")

# The same calls as a HAR file, as browser developer tools and Fiddler read it.
os.makedirs("out", exist_ok=True)
with contextlib.redirect_stdout(io.StringIO()):
    net.export(recorded, argparse.Namespace(**{**vars(args), "file": "calls.har", "har": True, "filter": None, "decrypted": False}))
with open("out/calls.har") as f:
    log = json.load(f)["log"]
assert log["version"] == "1.2" and len(log["entries"]) == 4, log
form_entry = log["entries"][3]
assert form_entry["request"]["method"] == "POST" and form_entry["request"]["httpVersion"] == "h3", form_entry["request"]
assert form_entry["request"]["postData"]["text"] == "name=alice&pin=1234", form_entry["request"]["postData"]
assert {"name": "x-asked", "value": "by curl"} in form_entry["request"]["headers"], form_entry["request"]["headers"]
assert form_entry["response"]["status"] == 200 and json.loads(form_entry["response"]["content"]["text"])["got"] == "name=alice&pin=1234", form_entry["response"]
assert form_entry["startedDateTime"].endswith("Z") and form_entry["timings"]["wait"] >= 0 and form_entry["connection"].startswith("u"), form_entry
print("the calls are written as HAR")

# After the server's key update the client holds only the secrets after it, which keys scan finds and tshark cannot open the
# connection with, so guest-net opens what came after the update itself, without the header protection key.
os.makedirs("late", exist_ok=True)
for name in ("net.pcapng", "capture.json"):
    shutil.copy(os.path.join("capture", name), os.path.join("late", name))
hello = next(iter(scan.quic_hellos(recorded).values()))
scanner = scan.Scanner(library)
with open("keys.full") as f:
    first_secrets = [line.split() for line in f if line.startswith(("CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0"))]
with open("late/updated.log", "w") as out:
    out.writelines(f"{label[:-1]}1 {random} {scanner.quic_next(1, hello['suite'], bytes.fromhex(secret)).hex()}\n" for label, random, secret in first_secrets)
moved = capture.Capture("late")
tshark_alone = subprocess.run([f"{wireshark}/tshark", "-n", "-r", "late/net.pcapng", "-o", "tls.keylog_file:late/updated.log", "-Y", "quic.stream_data"],
                              capture_output=True, text=True, check=True).stdout
assert not tshark_alone.strip(), "tshark opened QUIC with secrets after an update, so this test no longer tests what it should"
after = net.exchanges(moved, args)
listed = [(r["method"], r["url"].rsplit("/", 1)[-1], r["status"], r["version"]) for r in after]
# The first request went before the update and only its answer after, and the host each named was in the client's table.
assert listed == [("?", "(asked before the key update it was read from)", "200", "3"), ("GET", "second", "200", "3"),
                  ("GET", "third", "200", "3"), ("POST", "form", "200", "3")], listed
assert after[1]["url"].startswith("https://?/") and after[0]["flow"] == after[1]["flow"] == found[0]["flow"], after
with contextlib.redirect_stdout(io.StringIO()) as out:
    net.http(moved, argparse.Namespace(**{**vars(args), "id": after[3]["id"]}))
form = out.getvalue()
assert "POST https://?/form" in form and "name=alice&pin=1234" in form and '"got": "name=alice&pin=1234"' in form, form
assert "?: (set before the update)" in form and "x-answered: by aioquic" in form, form
print("after a key update, the requests and answers from then on are read with the secrets after it alone")

# keys scan on the same capture: the flow's first secrets are not in the memory, so it takes the flow's last packets from
# the capture and finds the secrets after the update among made up memory.
looked = argparse.Namespace(since=None, until=None, flow=None, again=True)
opening = scan.quic_sessions(moved, looked, net.flows(moved, None), {})
assert len(opening) == 1 and opening[0].quic == 1 and not opening[0].epochs, opening
latest = scan.late_quic_sessions(moved, looked, opening)
assert len(latest) == 1 and {side for side, *_ in latest[0].records} == {0, 1}, latest
with open("late/updated.log") as f:
    hidden = {label: bytes.fromhex(secret) for label, _, secret in (line.split() for line in f)}
memory = bytearray(os.urandom(1 << 16))
memory[1024: 1024 + len(hidden["CLIENT_TRAFFIC_SECRET_1"])] = hidden["CLIENT_TRAFFIC_SECRET_1"]
memory[9000: 9000 + len(hidden["SERVER_TRAFFIC_SECRET_1"])] = hidden["SERVER_TRAFFIC_SECRET_1"]
hits = scanner.scan(memory, len(memory), 0, latest, step=8)
assert {(hit.label, hit.secret) for hit in hits} == set(hidden.items()), [(hit.label, hit.address) for hit in hits]
print("keys scan takes a QUIC flow's last packets from the capture and finds its secrets after the update with them")

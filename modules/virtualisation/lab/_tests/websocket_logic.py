"""guest-net ws: a WebSocket of HTTP/1 in a capture written as the session writes it, read by the real tshark. The client masks
its frames, both sides use permessage-deflate and the server keeps its window between messages, so its second message
reads only with its first. A message comes in two fragments with a ping between them. One of HTTP/3 is read from the bytes
of its stream, and frames a hostile guest sends break nothing.

usage: websocket_logic.py CAPTURE_CODE TSHARK_FOLDER"""
import argparse
import base64
import contextlib
import hashlib
import io
import json
import os
import struct
import sys
import time
import zlib

code, wireshark = sys.argv[1:3]
sys.path.insert(0, code)
import capture
import net
import websocket


def frame(opcode, payload, mask, rsv1=False, fin=True):
    head = bytes([(0x80 if fin else 0) | (0x40 if rsv1 else 0) | opcode])
    n = len(payload)
    length = bytes([n]) if n < 126 else bytes([126]) + struct.pack(">H", n) if n < 65536 else bytes([127]) + struct.pack(">Q", n)
    if not mask:
        return head + length + payload
    key = os.urandom(4)
    return head + bytes([length[0] | 0x80]) + length[1:] + key + bytes(b ^ key[i % 4] for i, b in enumerate(payload))


def deflated(compressor, text):
    return (compressor.compress(text) + compressor.flush(zlib.Z_SYNC_FLUSH))[:-4]


# The server keeps one compressor for all its messages, as with context takeover, and its second message refers to its first.
server, client = zlib.compressobj(wbits=-15), zlib.compressobj(wbits=-15)
key = base64.b64encode(os.urandom(16)).decode()
accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
request = (f"GET /chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n\r\n").encode()
answer = (f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n"
          "Sec-WebSocket-Extensions: permessage-deflate\r\n\r\n").encode()
repeated = b'{"echo": "a long enough line that the second time it is only a reference back", "n": 1}'
turns = [
    (0, request), (1, answer),
    (0, frame(1, b"hello server", True)),
    (1, frame(1, deflated(server, repeated), False, rsv1=True)),
    (1, frame(1, deflated(server, repeated), False, rsv1=True)),
    (0, frame(1, deflated(client, b'{"user":"alice","pin":1234}'), True, rsv1=True)),
    (0, frame(2, bytes(range(16)), True)),
    (1, frame(1, b"part one, ", False, fin=False) + frame(9, b"between", False) + frame(0, b"part two", False)),
    (0, frame(8, struct.pack(">H", 1000) + b"bye", True)),
    (1, frame(8, struct.pack(">H", 1000), False)),
]


def block(kind, body):
    body += bytes(-len(body) % 4)
    return struct.pack("<II", kind, len(body) + 12) + body + struct.pack("<I", len(body) + 12)


def option(code_, value):
    return struct.pack("<HH", code_, len(value)) + value + bytes(-len(value) % 4)


def checksum(header):
    total = sum(struct.unpack("!10H", header))
    total = (total >> 16) + (total & 0xFFFF)
    return ~(total + (total >> 16)) & 0xFFFF


ends, ports, seq, packets = [b"\x0a\x09\x09\x32", b"\x0a\x09\x09\x01"], [40000, 80], [1000, 5000], []


def tcp(side, flags, payload=b""):
    header = struct.pack("!HHIIBBHHH", ports[side], ports[1 - side], seq[side], seq[1 - side], 5 << 4, flags, 65535, 0, 0)
    ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 40 + len(payload), len(packets), 0, 64, 6, 0, ends[side], ends[1 - side]))
    ip[10:12] = struct.pack("!H", checksum(bytes(ip)))
    packets.append((side, bytes(ip) + header + payload))
    seq[side] += len(payload) + (1 if flags & 0x02 else 0)


tcp(0, 0x02)
tcp(1, 0x12)
tcp(0, 0x10)
for side, data in turns:
    tcp(side, 0x18, data)
start = time.time() - 60
os.makedirs("capture", exist_ok=True)
with open("capture/net.pcapng", "wb") as f:
    f.write(block(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1)))
    f.write(block(1, struct.pack("<HHI", 101, 0, 65535) + option(9, b"\x09") + option(0, b"")))
    for n, (side, data) in enumerate(packets):
        ns = int((start + 10 + n * 0.01) * 1e9)
        f.write(block(6, struct.pack("<IIIII", 0, ns >> 32, ns & 0xFFFFFFFF, len(data), len(data)) + data + bytes(-len(data) % 4)
                      + option(2, struct.pack("<I", 2 if side == 0 else 1)) + option(0, b"")))
with open("capture/capture.json", "w") as f:
    json.dump({"started": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(start)), "net": [{"name": "made", "mac": "-"}]}, f)
with open("box", "w") as f:
    f.write('#!/bin/sh\nwhile [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n')
os.chmod("box", 0o755)
capture.SETTINGS = capture.Settings("net", wireshark, os.path.abspath("box"), "-", "-", "-", "-", "-")
recorded = capture.Capture("capture")


def shown(**changes):
    args = argparse.Namespace(since=None, until=None, keys=None, process=None, children=False, host=None, id=None, save=None, body=2000, max=200)
    with contextlib.redirect_stdout(io.StringIO()) as out:
        net.ws(recorded, argparse.Namespace(**{**vars(args), **changes}))
    return out.getvalue()


listing = shown()
lines = listing.splitlines()
assert lines[0].startswith("t0 ") and "ws://ws.test/chat" in lines[0] and "permessage-deflate" in lines[0] and "9 messages" in lines[0], listing
assert "-> text 12 B  hello server" in listing, listing
assert listing.count(f"<- text {len(repeated)} B deflated  {repeated.decode()}") == 2, "the server's second message needs the window of its first"
assert '-> text 27 B deflated  {"user":"alice","pin":1234}' in listing, listing
assert "-> binary 16 B  00 01 02 03" in listing, listing
assert "<- ping 7 B  between" in listing and "<- text 18 B  part one, part two" in listing, "the ping has to come out between the fragments"
assert "-> close 5 B  1000 bye" in listing and "<- close 2 B  1000" in listing, listing
assert listing.index("<- ping 7 B  between") < listing.index("<- text 18 B  part one, part two"), listing
full = shown(id="t0")
assert '"user": "alice",' in full, "one WebSocket in full lays out its JSON"
os.makedirs("out", exist_ok=True)
shown(id="t0", save="chat.jsonl")
with open("out/chat.jsonl") as f:
    saved = [json.loads(line) for line in f]
assert len(saved) == 9 and saved[0] == {"socket": "t0", "time": saved[0]["time"], "sent": True, "kind": "text", "deflated": False, "text": "hello server"}, saved[0]
assert base64.b64decode(saved[4]["base64"]) == bytes(range(16)), saved[4]
print("a WebSocket of HTTP/1 is read both ways, fragments put together and permessage-deflate undone with the window kept")

# One that a CONNECT of HTTP/3 opened, whose frames come as the bytes of its stream.
connect = {"id": "h9.0", "version": "3", "time": str(start + 30), "flow": "u2", "url": "https://chat.test/socket", "protocol": "websocket",
           "asked": frame(1, b"over h3", True) + frame(8, struct.pack(">H", 1001), True), "body": frame(1, b"answered", False)}
real = net.exchanges
net.exchanges = lambda *args, **kwargs: [connect]
try:
    over = shown()
finally:
    net.exchanges = real
assert "h9.0" in over and "wss://chat.test/socket" in over and "-> text 7 B  over h3" in over and "<- text 8 B  answered" in over, over
assert "-> close 2 B  1001" in over, over
print("a WebSocket of HTTP/3 is read from the bytes of its stream")

hostile = b"\x81\xfe\xff\xff" + b"\x00" * 10 + b"\x81\x7f" + b"\xff" * 8 + b"\x82"
assert list(websocket.frames(hostile)) == [], "frames that claim more than there is have to be passed over"
messages = websocket.Messages()
said = messages.add(True, True, 1, b"\xff\xfe not deflate")
assert said[:3] == ("text", b"\xff\xfe not deflate", True) and said[3].startswith("not undone of permessage-deflate"), said
assert messages.add(True, False, 0, b"stray continuation") is None, "a continuation without a start is no message"
print("what a hostile guest sends breaks nothing")

"""keys own on made up memory and a made up capture.

libtlsscan has to find the key of each cipher keys own knows among noise, with each check a decoder can set, an IV read
beside its key, a key that is text and one at an odd place, and has to keep out a key one bit off. own.py has to refuse
tests that check nothing or do not fit. Then keys own as a whole, on a capture of datagrams a client sent under AES-CBC
and a server answered under ChaCha20-Poly1305, with memory that holds both keys, a copy of one and one a bit off, and a
decoder whose test for AES-CBC is only the padding, which about one window in 250 passes: judging has to keep only the
two keys, which go to the capture, and decode has to hand them to the decoder.

usage: own_logic.py CAPTURE_CODE TSHARK_FOLDER LIBTLSSCAN DECODER"""
import argparse
import contextlib
import io
import json
import os
import random
import re
import struct
import sys
import time

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305

try:
    from cryptography.hazmat.decrepit.ciphers.algorithms import ARC4, TripleDES
except ImportError:
    ARC4, TripleDES = algorithms.ARC4, algorithms.TripleDES

code, wireshark, library, decoder = sys.argv[1:5]
sys.path.insert(0, code)
import capture
import net
import own
import scan


def encrypted(algorithm, mode, data):
    encrypting = Cipher(algorithm, mode).encryptor()
    return encrypting.update(data) + encrypting.finalize()


def padded(data, bits=128):
    padder = padding.PKCS7(bits).padder()
    return padder.update(data) + padder.finalize()


BASE = 0x7FF600000000
memory = bytearray(os.urandom(4 << 20))
spots = iter(range(0x1000, len(memory) - 0x1000, 0x8000))


def plant(data, offset=0):
    at = next(spots) + offset
    memory[at: at + len(data)] = data
    return BASE + at


scanner = scan.Scanner(library)


def found(spec, step=8, length=None, at=0):
    tests = own.tests_from({"tests": [spec]})
    hits, count = scanner.own(memory, length or len(memory), BASE + at, tests, step, scan.threads(), at=at)
    assert count == len(hits), count
    # As keys own keeps them: the IV only where it was read beside the key.
    return {(tests[i].label, key, iv if tests[i].beside is not None else b"", place) for i, key, iv, place in hits}


key, iv = os.urandom(32), os.urandom(16)
data = encrypted(algorithms.AES(key), modes.ECB(), b"MAGIC123" + b"\x00" * 24)
where = plant(key)
plant(bytes([key[0] ^ 1]) + key[1:])
assert found({"cipher": "aes-ecb", "key": 32, "data": data.hex(), "known": {"bytes": b"MAGIC123".hex()}}) == {("aes-256-ecb", key, b"", where)}

key, iv = os.urandom(16), os.urandom(16)
data = encrypted(algorithms.AES(key), modes.CBC(iv), padded(b"hello, this is text in a message"))
where = plant(key)
assert found({"cipher": "aes-cbc", "iv": iv.hex(), "data": data.hex(), "padded": True, "printable": 16, "span": 16}) == {("aes-128-cbc", key, b"", where)}

key, iv = os.urandom(24), os.urandom(16)
data = encrypted(algorithms.AES(key), modes.CTR(iv), b"the counter mode of AES, text only, long enough to tell" * 2)
where = plant(key)
assert found({"cipher": "aes-ctr", "iv": iv.hex(), "data": data.hex(), "printable": 32, "span": 32}) == {("aes-192-ctr", key, b"", where)}

key, nonce = os.urandom(32), os.urandom(12)
data = AESGCM(key).encrypt(nonce, os.urandom(40), b"header")
where = plant(key)
assert found({"cipher": "aes-gcm", "key": 32, "iv": nonce.hex(), "data": data.hex(), "aad": b"header".hex()}) == {("aes-256-gcm", key, b"", where)}

key, iv = os.urandom(32), os.urandom(16)
plain = b"\x01\x02\x03\x04ABCD" + os.urandom(24)
data = encrypted(algorithms.ChaCha20(key, iv), None, plain)
where = plant(key)
# The mask leaves out the bytes the decoder does not know.
known = bytes([plain[0], 0x55, plain[2], 0x55]) + plain[4:8]
assert found({"cipher": "chacha20", "iv": iv.hex(), "data": data.hex(), "known": {"bytes": known.hex(), "mask": "ff00ff00ffffffff"}}) == {("chacha20", key, b"", where)}

key, nonce = os.urandom(32), os.urandom(12)
data = ChaCha20Poly1305(key).encrypt(nonce, b"under ChaCha20-Poly1305", None)
where = plant(key)
assert found({"cipher": "chacha20-poly1305", "iv": nonce.hex(), "data": data.hex()}) == {("chacha20-poly1305", key, b"", where)}

key = b"s3cr3t!k"
data = encrypted(ARC4(key), None, b"PING-PONG from RC4")
where = plant(key)
assert found({"cipher": "rc4", "key": [6, 7, 8, 9], "data": data.hex(), "known": {"bytes": b"PING-P".hex()}}) == {("rc4", key, b"", where)}

key, iv = os.urandom(24), os.urandom(8)
data = encrypted(TripleDES(key), modes.CBC(iv), padded(b"3DES message!", 64))
where = plant(key)
assert found({"cipher": "3des-cbc", "iv": iv.hex(), "data": data.hex(), "padded": True, "known": {"bytes": b"3DES".hex()}}) == {("3des-cbc", key, b"", where)}
print("the key of each cipher is found among noise with each kind of check, and one a bit off is not")

key, iv = os.urandom(16), os.urandom(16)
data = encrypted(algorithms.AES(key), modes.CBC(iv), padded(b"BESIDE!! the IV is kept 32 bytes after the key"))
where = plant(key + os.urandom(16) + iv)
assert found({"cipher": "aes-cbc", "key": 16, "iv": {"beside": 32}, "data": data.hex(), "known": {"bytes": b"BESIDE!!".hex()}}) == {("aes-128-cbc", key, iv, where)}

key, iv = b"ThisIsASecretKey", os.urandom(16)
data = encrypted(algorithms.AES(key), modes.CBC(iv), padded(b'{"text": "under a key that is text"}'))
where = plant(key)
assert found({"cipher": "aes-cbc", "key": 16, "iv": iv.hex(), "data": data.hex(), "known": {"bytes": b'{"text'.hex()}}) == {("aes-128-cbc", key, b"", where)}

key, iv = os.urandom(16), os.urandom(16)
data = encrypted(algorithms.AES(key), modes.CBC(iv), padded(b"at an odd place, found trying every one"))
where = plant(key, 3)
start = where - BASE - 1000
assert found({"cipher": "aes-cbc", "key": 16, "iv": iv.hex(), "data": data.hex(), "known": {"bytes": b"at an odd".hex()}}, step=1, length=65536, at=start) == {
    ("aes-128-cbc", key, b"", where)}
print("an IV beside its key, a key that is text and one at an odd place are found")

refusals = [
    ({"tests": []}, "with a test in it"),
    ({"tests": [{"cipher": "aes-xts", "data": "00" * 16}]}, "cipher is one of"),
    ({"tests": [{"cipher": "aes-cbc", "iv": "00" * 16, "data": "00" * 16}]}, "checks nothing"),
    ({"tests": [{"cipher": "aes-cbc", "iv": "00" * 16, "data": "00" * 15, "padded": True}]}, "whole blocks of 16"),
    ({"tests": [{"cipher": "aes-gcm", "iv": "00" * 16, "data": "00" * 32}]}, "the iv of aes-gcm is 12 bytes"),
    ({"tests": [{"cipher": "aes-ctr", "iv": "00" * 16, "data": "00" * 8, "known": {"at": 7, "bytes": "0000"}}]}, "past the end"),
    ({"tests": [{"cipher": "rc4", "data": "00" * 8, "printable": 4}]}, "key is the length"),
    ({"tests": [{"cipher": "rc4", "key": 8, "data": "00" * 8, "printable": 9, "span": 8}]}, "printable is at most span"),
    ({"tests": [{"cipher": "rc4", "key": 8, "data": "00" * 8, "printable": 4, "run": "x"}]}, "fields a test has not"),
    ({"tests": [{"cipher": "aes-ecb", "data": "zz", "printable": 1}]}, "written in hex"),
    ({"tests": [{"cipher": "aes-ecb", "data": "00" * 16, "printable": 1}] * 30}, "at most 64"),
]
for answer, told in refusals:
    try:
        own.tests_from(answer)
    except own.Unfit as e:
        assert told in str(e), (told, str(e))
    else:
        raise AssertionError(f"{answer} was taken")
print("tests that check nothing or do not fit are refused, each with what is wrong")


def option(kind, value):
    return struct.pack("<HH", kind, len(value)) + value + bytes(-len(value) % 4)


def block(kind, body):
    body += bytes(-len(body) % 4)
    return struct.pack("<II", kind, len(body) + 12) + body + struct.pack("<I", len(body) + 12)


def checksum(header):
    total = sum(struct.unpack("!10H", header))
    total = (total >> 16) + (total & 0xFFFF)
    return ~(total + (total >> 16)) & 0xFFFF


asking, answering = os.urandom(32), os.urandom(32)
datagrams, stamp = [], time.time() - 60
for n in range(5):
    iv, nonce = os.urandom(16), os.urandom(12)
    datagrams.append((True, stamp + n, iv + encrypted(algorithms.AES(asking), modes.CBC(iv), padded(json.dumps({"n": n, "say": f"hello {n}"}).encode()))))
    datagrams.append((False, stamp + n + 0.5, nonce + ChaCha20Poly1305(answering).encrypt(nonce, json.dumps({"n": n, "answer": f"heard {n}"}).encode(), None)))
# As the session writes it: nanosecond times, and each frame's direction seen from the guest, which is the client here.
os.makedirs("capture", exist_ok=True)
with open("capture/net.pcapng", "wb") as f:
    f.write(block(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1)))
    f.write(block(1, struct.pack("<HHI", 101, 0, 65535) + option(9, b"\x09") + option(0, b"")))
    for number, (sent, when, payload) in enumerate(datagrams):
        ends = (b"\x0a\x09\x09\x32", b"\x0a\x09\x09\x01") if sent else (b"\x0a\x09\x09\x01", b"\x0a\x09\x09\x32")
        ports = (40000, 9999) if sent else (9999, 40000)
        udp = struct.pack("!HHHH", *ports, 8 + len(payload), 0) + payload
        header = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), number, 0, 64, 17, 0, *ends))
        header[10:12] = struct.pack("!H", checksum(bytes(header)))
        frame = bytes(header) + udp
        nanoseconds = int(when * 1e9)
        f.write(block(6, struct.pack("<IIIII", 0, nanoseconds >> 32, nanoseconds & 0xFFFFFFFF, len(frame), len(frame)) + frame
                      + bytes(-len(frame) % 4) + option(2, struct.pack("<I", 2 if sent else 1)) + option(0, b"")))
with open("capture/capture.json", "w") as f:
    json.dump({"started": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stamp - 1)), "net": [{"name": "made up", "mac": "-"}]}, f)

# lab-box is the lab's, and here everything runs in the build's sandbox already.
with open("box", "w") as f:
    f.write('#!/bin/sh\nwhile [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n')
os.chmod("box", 0o755)
capture.SETTINGS = capture.Settings("net", wireshark, os.path.abspath("box"), "-", "-", "-", library, "-")
recorded = capture.Capture("capture")

# The same noise each time, so that as many windows pass the padding alone each time.
ram = bytearray(random.Random(7).randbytes(128 << 10))
for at, kept in ((0x2000, asking), (0x9008, asking), (0x12010, answering), (0x15000, bytes([asking[0] ^ 0x80]) + asking[1:])):
    ram[at: at + 32] = kept


class Ram:
    def __str__(self):
        return "the made up RAM"

    def regions(self, budget):
        return [(BASE, ram, len(ram))]


noted = []
scan.Physical, own.tell = Ram, lambda request, needed=True: noted.append(request)
with open(decoder) as f:
    weak = f.read().replace(', "padded": True, "known": {"bytes": b\'{"\'.hex()}}', ', "padded": True}')
assert weak.count('"padded": True}') == 1, "the test decoder changed, so this no longer makes its AES-CBC test weak"
with open("weak_decoder.py", "w") as f:
    f.write(weak)
args = argparse.Namespace(action="own", flow=["u0"], decoder="weak_decoder.py", physical=True, process=None, all=False, step=8, max_memory=64,
                          since=None, until=None, decrypted=False)
with contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()) as told:
    net.keys(recorded, args)
said, err = out.getvalue(), told.getvalue()
print(err + said, end="")
judged = re.search(r"2 of (\d+) candidates the decoder judged to open the flow", err)
assert judged and int(judged.group(1)) > 50, err
assert re.search(rf"u0 +aes-256-cbc  key {asking.hex()}  at {BASE + 0x2000:#x} and 1 more  in the made up RAM", said), said
assert re.search(rf"u0 +chacha20-poly1305  key {answering.hex()}  at {BASE + 0x12010:#x}  in the made up RAM", said), said
entries = [entry for note in noted for entry in note["entries"]]
assert {(e["cipher"], e["key"]) for e in entries} == {("aes-256-cbc", asking.hex()), ("chacha20-poly1305", answering.hex())}, entries
assert all(note["kind"] == "own" for note in noted), noted
print("keys own judges what passed a weak test with the decoder and notes only the two keys that open the flow")

# The session keeps what keys own notes, and decode hands it to the decoder.
with open("capture/own.jsonl", "w") as f:
    f.writelines(json.dumps({"time": 1, **entry}) + "\n" for entry in entries)
recorded = capture.Capture("capture")
with contextlib.redirect_stdout(io.StringIO()) as out:
    net.decode(recorded, argparse.Namespace(id="u0", decoder=decoder, arguments=[], save=None, decrypted=False, keys=None, since=None, until=None))
lines = out.getvalue().splitlines()
assert lines == [line for n in range(5) for line in (f'-> {{"n": {n}, "say": "hello {n}"}}', f'<- {{"n": {n}, "answer": "heard {n}"}}')], lines
with contextlib.redirect_stdout(io.StringIO()) as out:
    net.keys(recorded, argparse.Namespace(action="list"))
assert "own u0 aes-256-cbc 1" in out.getvalue() and "own u0 chacha20-poly1305 1" in out.getvalue(), out.getvalue()
print("decode hands the keys keys own found to the decoder, which reads every message both ways with them")

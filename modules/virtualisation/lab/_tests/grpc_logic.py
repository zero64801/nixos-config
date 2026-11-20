"""gRPC in guest-net: messages behind their flags and lengths, one of them gzipped, decoded by their wire format alone and
named by protoc with the program's .proto file, shown in a request of HTTP/3 with the answer's grpc-status, gRPC-Web's
text with its trailers in the body, and a hostile guest's lengths, wire types and nesting.

usage: grpc_logic.py CAPTURE_CODE PROTOC"""
import argparse
import base64
import contextlib
import gzip
import io
import os
import sys

code, protoc = sys.argv[1:3]
sys.path.insert(0, code)
import capture
import grpc
import net


def varint(value):
    out = bytearray()
    while True:
        out.append(value & 0x7F | (0x80 if value > 0x7F else 0))
        value >>= 7
        if not value:
            return bytes(out)


def field(number, kind, value):
    key = varint(number << 3 | kind)
    if kind == 0:
        return key + varint(value)
    if kind == 2:
        return key + varint(len(value)) + value
    return key + value


def framed(payload, flags=0):
    return bytes([flags]) + len(payload).to_bytes(4, "big") + payload


inner = field(1, 5, (7).to_bytes(4, "little"))
hello = field(1, 2, b"alice") + field(2, 0, 150) + field(3, 2, inner)
reply = field(1, 2, b"hello alice") + field(2, 0, 1) + field(2, 0, 2) + field(9, 1, (1 << 40).to_bytes(8, "little")) + field(10, 2, b"\x00\xff\x01")

assert grpc.raw(hello) == '1: "alice"\n2: 150\n3 {\n  1: 0x00000007\n}', grpc.raw(hello)
assert grpc.raw(reply) == '1: "hello alice"\n2: 1\n2: 2\n9: 0x0000010000000000\n10: bytes 00 ff 01', grpc.raw(reply)
print("messages read by their wire format alone")

os.makedirs("proto/demo", exist_ok=True)
with open("proto/demo/greeter.proto", "w") as f:
    f.write("""syntax = "proto3";
package demo;
// A comment that names rpc Other (Wrong) returns (Wrong) to be passed over.
service Greeter {
  rpc Hello (HelloRequest) returns (HelloReply);
  rpc Many (stream HelloRequest) returns (stream HelloReply);
}
message Inner { fixed32 code = 1; }
message HelloRequest { string name = 1; int32 times = 2; Inner inner = 3; }
message HelloReply { string message = 1; repeated int32 counts = 2 [packed = false]; fixed64 big = 9; bytes blob = 10; }
""")
assert grpc.types("proto", "/demo.Greeter/Hello") == ("demo.HelloRequest", "demo.HelloReply")
assert grpc.types("proto", "/demo.Greeter/Many") == ("demo.HelloRequest", "demo.HelloReply")
assert grpc.types("proto", "/demo.Greeter/Other") is None and grpc.types("proto", "/other.Greeter/Hello") is None

with open("box", "w") as f:
    f.write('#!/bin/sh\nwhile [ "$1" != -- ]; do [ "$1" = --chdir ] && cd "$2"; shift; done\nshift\nexec "$@"\n')
os.chmod("box", 0o755)
text, why = grpc.named(os.path.abspath("box"), protoc, os.path.abspath("proto"), "demo.HelloRequest", hello)
assert why is None and 'name: "alice"' in text and "times: 150" in text and "code: 7" in text, (text, why)
print("messages named by protoc with the program's .proto file")

capture.SETTINGS = capture.Settings("net", "-", os.path.abspath("box"), "-", "-", "-", "-", protoc)
call = {"id": "h7.0", "version": "3", "time": "1", "flow": "u1", "method": "POST", "url": "https://api.test/demo.Greeter/Hello", "status": "200",
        "type": "application/grpc", "size": "", "took": 0.01, "protocol": "",
        "sent": [(":method", "POST"), (":path", "/demo.Greeter/Hello"), ("content-type", "application/grpc"), ("grpc-encoding", "gzip")],
        "got": [(":status", "200"), ("grpc-encoding", "identity"), ("grpc-status", "0"), ("grpc-message", "fine")],
        "asked": framed(gzip.compress(hello), 1), "body": framed(reply) + framed(reply)}
net.exchanges = lambda *args, **kwargs: [call]


class Empty:
    """A capture with nothing recorded beside the call, which exchanges gives, in a folder with no keys of its own."""

    folder = "."

    def lines(self, name):
        return iter(())

    def relative(self, stamp):
        return "+0.00s"


def shown(**changes):
    args = argparse.Namespace(since=None, until=None, keys=None, process=None, children=False, host=None, id="h7.0", max=300, body=4000, save=None,
                              request=False, proto=None, type=None)
    with contextlib.redirect_stdout(io.StringIO()) as out:
        net.http(Empty(), argparse.Namespace(**{**vars(args), **changes}))
    return out.getvalue()


plain_view = shown()
assert "request body, gRPC:" in plain_view and "message 0, 17 B, gzip" in plain_view and '    1: "alice"' in plain_view, plain_view
assert "body, gRPC:" in plain_view and "message 1, " in plain_view and '1: "hello alice"' in plain_view, plain_view
assert "grpc-status: 0" in plain_view and "grpc-message: fine" in plain_view, plain_view
named_view = shown(proto=os.path.abspath("proto"))
assert "as demo.HelloRequest" in named_view and 'name: "alice"' in named_view and "as demo.HelloReply" in named_view, named_view
assert 'message: "hello alice"' in named_view and "counts: 2" in named_view, named_view
print("a call of gRPC shows its messages both ways, gzipped or not, with names and without")

web = base64.b64encode(framed(hello) + framed(b"grpc-status:0\r\ngrpc-message:ok\r\n", 0x80))
lines = grpc.shown(web, {"content-type": "application/grpc-web-text"}, "/demo.Greeter/Hello", False)
assert any("trailers: grpc-status:0; grpc-message:ok" in line for line in lines) and any('1: "alice"' in line for line in lines), lines
print("gRPC-Web's text and the trailers it keeps in its body")

assert list(grpc.messages(b"\x00\xff\xff\xff\xff" + b"x" * 10)) == [], "a message longer than the body has to be passed over"
broken = grpc.shown(framed(b"\x0f\x01"), {}, "", True)
assert any("no protobuf (wire type 7)" in line for line in broken), broken
deep = b"\x08\x01"
for _ in range(100):
    deep = field(1, 2, deep)
assert grpc.raw(deep).count("{") == grpc.DEPTH, "nesting has to stop at the depth set"
endless = grpc.shown(framed(b"\x08" + b"\xff" * 20), {}, "", True)
assert any("no protobuf" in line for line in endless), endless
print("what a hostile guest sends breaks nothing")

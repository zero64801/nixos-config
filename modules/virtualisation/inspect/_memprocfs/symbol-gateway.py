"""Hands Microsoft debug symbol files to a program without network, over a unix socket.

usage: pdb-symbol-gateway SOCKET CACHE [SERVER]

A request is one line, "NAME.pdb GUIDAGE". The answer is the length in bytes on a line, then the file, or 0 for none.
Nothing but a file name and an identifier of the expected shape leaves through here, and nothing but that file comes back.
"""
import os
import re
import socketserver
import sys
import tempfile
import urllib.request

REQUEST = re.compile(rb"([A-Za-z0-9][A-Za-z0-9_.-]{0,63}\.pdb) ([0-9A-Fa-f]{33,40})\n")
SMALLEST, LARGEST = 0x1000, 0x04000000

socket_path, cache = sys.argv[1], sys.argv[2]
server = sys.argv[3] if len(sys.argv) > 3 else "https://msdl.microsoft.com/download/symbols"


def symbol(name, identifier):
    path = os.path.join(cache, name, identifier, name)
    if not os.path.isfile(path):
        with urllib.request.urlopen(f"{server}/{name}/{identifier}/{name}", timeout=60) as response:
            data = response.read(LARGEST + 1)
        if not SMALLEST <= len(data) <= LARGEST:
            raise ValueError(f"{len(data)} bytes is not the size of a symbol file")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        handle, partial = tempfile.mkstemp(dir=os.path.dirname(path))
        with os.fdopen(handle, "wb") as file:
            file.write(data)
        os.replace(partial, path)
        print(f"symbol gateway: fetched {name} {identifier}", file=sys.stderr)
    with open(path, "rb") as file:
        return file.read()


class Request(socketserver.StreamRequestHandler):
    def handle(self):
        data = b""
        match = REQUEST.fullmatch(self.rfile.readline(128))
        if match:
            name, identifier = match.group(1).decode(), match.group(2).decode().upper()
            try:
                data = symbol(name, identifier)
            except Exception as error:
                print(f"symbol gateway: {name} {identifier}: {error}", file=sys.stderr)
        self.wfile.write(b"%d\n" % len(data) + data)


if os.path.exists(socket_path):
    os.unlink(socket_path)
with socketserver.ThreadingUnixStreamServer(socket_path, Request) as gateway:
    gateway.serve_forever()

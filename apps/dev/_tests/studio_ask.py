"""Sends one request line to the Studio broker and prints its reply line.

Bytes after that line are pixels, summed up on a second line as their count and the distinct 4 byte values.
"""
import json
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
    conn.settimeout(30)
    conn.connect(sys.argv[1])
    conn.sendall(sys.argv[2].encode() + b"\n")
    conn.shutdown(socket.SHUT_WR)
    reply = b""
    while chunk := conn.recv(65536):
        reply += chunk
header, _, pixels = reply.partition(b"\n")
print(header.decode())
if pixels:
    distinct = {pixels[i:i + 4].hex() for i in range(0, len(pixels), 4)}
    print(json.dumps({"bytes": len(pixels), "pixels": sorted(distinct)[:8]}))

"""Sends one request line to the Studio broker and prints its reply line."""
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
sys.stdout.write(reply.decode())

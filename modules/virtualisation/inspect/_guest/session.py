"""What every guest tool needs of an open vm-inspect session: where it is, and how to ask it one thing.

The tools decide nothing themselves. The helper that opened the guest checks every request.
"""
import json
import os
import socket
import sys


def fail(message):
    print(f"guest-{sys.argv[1] if len(sys.argv) > 1 else 'tool'}: {message}", file=sys.stderr)
    sys.exit(1)


class Refused(Exception):
    """The session said no, with its reason."""


def session_folder():
    folder = os.environ.get("VM_INSPECT_DIR")
    if not folder:
        fail("this runs inside a vm-inspect session")
    return folder


def control_socket():
    return os.path.join(session_folder(), "control.sock")


def ask(path, request, carrying=(), patience=60):
    """The session's answer to one request, and the descriptor it came with, if any. Refused when it says no."""
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(patience)
    try:
        conn.connect(path)
    except OSError:
        fail("no session is open for this guest, or it is one from before screens and input were added")
    line, descriptors = b"", []
    with conn:
        try:
            if carrying:
                socket.send_fds(conn, [json.dumps(request).encode() + b"\n"], list(carrying))
            else:
                conn.sendall(json.dumps(request).encode() + b"\n")
            while not line.endswith(b"\n"):
                more, received, _, _ = socket.recv_fds(conn, 4096, 4)
                descriptors += received
                if not more:
                    break
                line += more
        except OSError as e:
            fail(f"the session did not answer: {e}")
    try:
        reply = json.loads(line)
    except ValueError:
        fail("the session ended before it answered")
    if not isinstance(reply, dict) or "error" in reply:
        for descriptor in descriptors:
            os.close(descriptor)
        raise Refused(str(reply.get("error")) if isinstance(reply, dict) else "the session gave an answer that makes no sense")
    return reply, descriptors


def carried(reply, descriptors, limit):
    """What came as a descriptor with an answer, when it is the size the session said and no larger than allowed."""
    if len(descriptors) != 1:
        fail("the session's answer came without what it should carry")
    with os.fdopen(descriptors[0], "rb") as f:
        data = f.read(limit + 1)
    if len(data) > limit or len(data) != reply.get("size"):
        fail("the session's answer is not the size it said")
    return data

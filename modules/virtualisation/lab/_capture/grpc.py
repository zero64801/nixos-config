"""gRPC in a body of HTTP/2 or HTTP/3, or of gRPC-Web: its messages, each behind a byte of flags and four of length, undone
of grpc-encoding when compressed, and decoded as protobuf. Without the program's .proto files a message reads by its wire
format alone, as protoc --decode_raw reads it: field numbers, varints, fixed numbers and length delimited bytes, which are
a nested message where they parse as one, text where they read as text and bytes otherwise. With them protoc names every
field, inside lab-box, since it is C++ on the guest's bytes. Every length here was chosen by the guest and is checked."""
import base64
import os
import re
import subprocess

import bodies

DEPTH = 32


def messages(data):
    """(flags, payload) of each message, up to the first that is cut off. A flag of 0x80 is a trailer of gRPC-Web."""
    at = 0
    while at + 5 <= len(data):
        flags, length = data[at], int.from_bytes(data[at + 1: at + 5], "big")
        if at + 5 + length > len(data):
            return
        yield flags, data[at + 5: at + 5 + length]
        at += 5 + length


def varint(data, at):
    value, shift = 0, 0
    while at < len(data) and shift < 70:
        value |= (data[at] & 0x7F) << shift
        at, shift = at + 1, shift + 7
        if not data[at - 1] & 0x80:
            return value, at
    raise ValueError("a varint that does not end")


def fields(data):
    """(number, wire type, value) of each field of a message, or ValueError where it is no protobuf."""
    found, at = [], 0
    while at < len(data):
        key, at = varint(data, at)
        number, kind = key >> 3, key & 7
        if number == 0:
            raise ValueError("field number 0")
        if kind == 0:
            value, at = varint(data, at)
        elif kind == 1:
            if at + 8 > len(data):
                raise ValueError("a fixed64 cut off")
            value, at = data[at: at + 8], at + 8
        elif kind == 2:
            length, at = varint(data, at)
            if at + length > len(data):
                raise ValueError("bytes cut off")
            value, at = data[at: at + length], at + length
        elif kind == 5:
            if at + 4 > len(data):
                raise ValueError("a fixed32 cut off")
            value, at = data[at: at + 4], at + 4
        else:
            raise ValueError(f"wire type {kind}")
        found.append((number, kind, value))
    return found


def printable(data):
    try:
        words = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return words if all(c.isprintable() or c in "\t\n\r" for c in words) else None


def raw(data, depth=0):
    """The message by its wire format alone, one field a line, nested messages indented."""
    lines, pad = [], "  " * depth
    for number, kind, value in fields(data):
        if kind == 0:
            lines.append(f"{pad}{number}: {value}")
        elif kind in (1, 5):
            lines.append(f"{pad}{number}: 0x{int.from_bytes(value, 'little'):0{len(value) * 2}x}")
        else:
            nested = None
            if value and depth < DEPTH and printable(value) is None:
                try:
                    nested = raw(value, depth + 1)
                except ValueError:
                    nested = None
            if nested is not None:
                lines += [f"{pad}{number} {{", nested, f"{pad}}}"]
            elif printable(value) is not None:
                lines.append(f'{pad}{number}: "{printable(value)}"')
            else:
                lines.append(f"{pad}{number}: bytes {value[:64].hex(' ')}{' ...' if len(value) > 64 else ''}")
    return "\n".join(lines)


def types(folder, path):
    """The request's and the answer's message types of the method a path of gRPC names, /package.Service/Method, from the
    .proto files under the folder, as protoc names them, or None."""
    matched = re.fullmatch(r"/(?:([\w.]+)\.)?(\w+)/(\w+)", path)
    if not matched:
        return None
    package, service, method = matched.groups()
    for root, _, names in os.walk(folder):
        for name in names:
            if not name.endswith(".proto"):
                continue
            with open(os.path.join(root, name), errors="replace") as f:
                text = re.sub(r"//[^\n]*|/\*.*?\*/", "", f.read(), flags=re.DOTALL)
            declared = re.search(r"\bpackage\s+([\w.]+)\s*;", text)
            if (declared.group(1) if declared else None) != package:
                continue
            block = re.search(rf"\bservice\s+{service}\s*\{{(.*?)\n\s*\}}", text, flags=re.DOTALL)
            rpc = block and re.search(rf"\brpc\s+{method}\s*\(\s*(?:stream\s+)?([\w.]+)\s*\)\s*returns\s*\(\s*(?:stream\s+)?([\w.]+)\s*\)", block.group(1))
            if rpc:
                return tuple(t if "." in t or not package else f"{package}.{t}" for t in rpc.groups())
    return None


def named(box, protoc, folder, kind, payload):
    """The message decoded by protoc with the .proto files under the folder, as kind, in lab-box, or why not."""
    files = [os.path.relpath(os.path.join(root, name), folder) for root, _, names in os.walk(folder) for name in names if name.endswith(".proto")]
    done = subprocess.run([box, "--ro", folder, "--chdir", folder, "--", protoc, "-I", folder, f"--decode={kind}", *files], input=payload,
                          capture_output=True, check=False)
    if done.returncode != 0:
        return None, done.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or ["protoc gave no reason"]
    return done.stdout.decode("utf-8", "replace").rstrip(), None


def shown(data, headers, path, request, proto=None, kind=None, box=None, protoc=None, limit=4000):
    """The lines that show a gRPC body: each message and the trailers gRPC-Web keeps in the body."""
    encoding = headers.get("grpc-encoding", "identity")
    if "grpc-web-text" in headers.get("content-type", ""):
        try:
            data = base64.b64decode(data)
        except ValueError:
            return ["  base64 of gRPC-Web text that does not decode"]
    wanted = (kind or (types(proto, path) or (None, None))[0 if request else 1]) if proto else None
    lines = []
    for number, (flags, payload) in enumerate(messages(data)):
        if flags & 0x80:
            lines.append("  trailers: " + "; ".join(line.strip() for line in payload.decode("latin1").splitlines() if line.strip()))
            continue
        note = ""
        if flags & 1:
            payload, note = bodies.decoded(payload, encoding)
        head = f"  message {number}, {len(payload)} B{', ' + encoding if flags & 1 else ''}{' (' + note + ')' if note else ''}"
        text, why = (named(box, protoc, proto, wanted, payload) if wanted else (None, None))
        if text is None:
            try:
                text = raw(payload)
            except ValueError as e:
                text = f"no protobuf ({e}): {payload[:64].hex(' ')}"
            if why:
                head += f", not named: {why[0]}"
        elif wanted:
            head += f", as {wanted}"
        lines += [head] + ["    " + line for line in text[:limit].splitlines()]
    return lines

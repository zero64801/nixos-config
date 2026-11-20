"""The messages of a WebSocket (RFC 6455), from its frames: fragments put together and permessage-deflate (RFC 7692)
undone. The frames come from tshark, which unmasks those of HTTP/1, or from frames(), which reads them out of the bytes of
an HTTP/2 or HTTP/3 stream that a CONNECT of :protocol websocket opened. Every frame was sent or received by the guest,
so every length is checked, and what is undone stops at bodies.LIMIT."""
import zlib

import bodies

KINDS = {0: "continuation", 1: "text", 2: "binary", 8: "close", 9: "ping", 10: "pong"}
CONTROL = 8
# What permessage-deflate leaves off the end of each message, and has to be put back to undo it.
TAIL = b"\x00\x00\xff\xff"


def frames(data):
    """(fin, compressed, opcode, payload) of each whole frame in the bytes of one direction, unmasked."""
    at = 0
    while at + 2 <= len(data):
        first, second = data[at], data[at + 1]
        length, at = second & 0x7F, at + 2
        if length >= 126:
            size = 2 if length == 126 else 8
            if at + size > len(data):
                return
            length, at = int.from_bytes(data[at: at + size], "big"), at + size
        key = b""
        if second & 0x80:
            key, at = data[at: at + 4], at + 4
        if at + length > len(data) or len(key) not in (0, 4):
            return
        payload = data[at: at + length]
        if key:
            payload = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
        yield bool(first & 0x80), bool(first & 0x40), first & 0x0F, payload
        at += length


class Messages:
    """The messages of one direction. A deflated message is undone with the window of those before it, which is right with
    context takeover and harmless without, since a message made without it never looks back."""

    def __init__(self):
        self.parts, self.compressed, self.kind, self.inflater = [], False, None, None

    def add(self, fin, compressed, opcode, payload):
        """A frame, and the message it ends as (kind, data, whether it was deflated, a note), or None."""
        if opcode >= CONTROL:
            return KINDS.get(opcode, f"opcode {opcode}"), payload, False, ""
        if opcode != 0:
            self.parts, self.compressed, self.kind = [], compressed, KINDS.get(opcode, f"opcode {opcode}")
        if self.kind is None:
            return None
        if sum(len(part) for part in self.parts) + len(payload) <= bodies.LIMIT:
            self.parts.append(payload)
        if not fin:
            return None
        data, note = b"".join(self.parts), ""
        if self.compressed:
            self.inflater = self.inflater or zlib.decompressobj(-15)
            try:
                data = self.inflater.decompress(data + TAIL, bodies.LIMIT)
            except zlib.error as e:
                data, note, self.inflater = b"".join(self.parts), f"not undone of permessage-deflate: {e}", None
        kind, self.kind, self.parts = self.kind, None, []
        return kind, data, self.compressed, note


def closed(data):
    """The status code and reason of a close frame."""
    if len(data) < 2:
        return "no status"
    reason = data[2:].decode("utf-8", "replace")
    return f"{int.from_bytes(data[:2], 'big')}" + (f" {reason}" if reason else "")

"""The requests of HTTP/3 in QUIC's stream data, which guest-net hands over on standard input as JSON, and their answers,
written as JSON to standard output. It runs inside lab-box, since the guest chose every byte and ls-qpack, which
undoes the headers' compression, is C.

Each connection's stream data comes in the order of the packets, as chunks of a stream at an offset, and is put back
together per stream and per side. The unidirectional streams carry each side's settings and the instructions for its
headers' table, the bidirectional ones a request and its answer as HTTP/3 frames.
"""
import base64
import json
import sys

import pylsqpack

LIMIT = 64 << 20
# HTTP/3's frames, settings and unidirectional streams, after RFC 9114 and RFC 9204.
DATA, HEADERS, SETTINGS = 0x00, 0x01, 0x04
TABLE_CAPACITY, BLOCKED_STREAMS = 0x01, 0x07
CONTROL, ENCODER = 0x00, 0x02


def varint(data, at):
    """A variable-length integer of QUIC at this offset and the offset after it, or None when the data ends before it."""
    if at >= len(data):
        return None
    length = 1 << (data[at] >> 6)
    if at + length > len(data):
        return None
    value = data[at] & 0x3F
    for byte in data[at + 1: at + length]:
        value = (value << 8) | byte
    return value, at + length


def prefixed(data, at, bits):
    """An integer of QPACK with a prefix of this many bits (RFC 7541 5.1) and the offset after it, or None."""
    if at >= len(data):
        return None
    mask = (1 << bits) - 1
    value, at, shift = data[at] & mask, at + 1, 0
    if value < mask:
        return value, at
    while at < len(data) and shift < 63:
        value, at, shift = value + ((data[at] & 0x7F) << shift), at + 1, shift + 7
        if not data[at - 1] & 0x80:
            return value, at
    return None


class Side:
    """What one side of a connection said: its settings and its own table of headers, which only it fills. sized says
    whether the table's decoder was made with what the other side allowed."""

    def __init__(self):
        self.settings, self.decoder, self.sized = {}, None, False


class Connection:
    def __init__(self, flow):
        self.flow, self.sides = flow, (Side(), Side())
        self.streams, self.requests, self.blocked, self.notes = {}, {}, {}, []

    def decoder(self, sender, first=b""):
        """The decoder of the headers this side sends, sized by what the other side allowed it. When the other side's
        settings went as early data the keys do not open, the size this side's encoder first sets the table to stands in,
        which is mostly the most it was allowed, and the decoder is made again once that first instruction comes."""
        side, allowed = self.sides[sender], self.sides[1 - sender].settings
        hinted = prefixed(first, 0, 5) if first[:1] and first[0] & 0xE0 == 0x20 else None
        if side.decoder is None or (not side.sized and hinted):
            if TABLE_CAPACITY in allowed:
                capacity, blocked, side.sized = allowed[TABLE_CAPACITY], allowed.get(BLOCKED_STREAMS, 0), True
            else:
                capacity, blocked, side.sized = hinted[0] if hinted else 0, 100, bool(hinted)
            side.decoder = pylsqpack.Decoder(min(capacity, 1 << 20), min(blocked, 1024))
        return side.decoder

    def take(self, event):
        """One chunk of a stream: placed at its offset, and what has become contiguous handled."""
        when, frame, sender, stream, offset, data, fin = event
        key = (stream, sender)
        state = self.streams.setdefault(key, {"data": bytearray(), "pieces": {}, "read": 0, "kind": None, "first": when, "frame": frame, "fin": False})
        if offset >= LIMIT:
            return
        state["pieces"][offset] = (data, when, frame)
        state["fin"] |= fin
        # Pieces may come out of order or again, and only what follows what is there already counts.
        moved = True
        while moved:
            moved = False
            for at in sorted(state["pieces"]):
                piece, when, frame = state["pieces"][at]
                end = at + len(piece)
                if at <= len(state["data"]) < end:
                    state["data"] += piece[len(state["data"]) - at:]
                    state["last"], state["last_frame"] = when, frame
                    moved = True
                if end <= len(state["data"]):
                    del state["pieces"][at]
        self.handle(key, state)

    def handle(self, key, state):
        stream, sender = key
        data = state["data"]
        if stream & 0x2:
            if state["kind"] is None:
                found = varint(data, 0)
                if found is None:
                    return
                state["kind"], state["read"] = found
                state["start"] = state["read"]
            if state["kind"] == ENCODER:
                if state["read"] < len(data):
                    first = bytes(data[state["read"]:]) if state["read"] == state["start"] else b""
                    try:
                        unblocked = self.decoder(sender, first).feed_encoder(bytes(data[state["read"]:]))
                    except pylsqpack.EncoderStreamError as e:
                        self.notes.append(f"{self.flow}: the table of headers of the {'client' if sender == 0 else 'server'} broke: {e}")
                        unblocked = []
                    state["read"] = len(data)
                    for blocked in unblocked:
                        waiting = self.blocked.pop((blocked, sender), None)
                        if waiting:
                            self.headers(waiting, sender, resume=True)
                            self.handle(waiting, self.streams[waiting])
                return
            if state["kind"] != CONTROL:
                return
        if key in self.blocked.values():
            return
        while True:
            head = varint(data, state["read"])
            size = head and varint(data, head[1])
            if size is None or size[1] + size[0] > len(data):
                if size and size[0] > LIMIT:
                    state["read"] = len(data)
                return
            kind, length, start = head[0], size[0], size[1]
            payload = bytes(data[start: start + length])
            state["read"] = start + length
            if stream & 0x2:
                if kind == SETTINGS:
                    self.settings(sender, payload)
                continue
            if kind == HEADERS:
                self.headers(key, sender, payload=payload)
                if key in self.blocked.values():
                    return
            elif kind == DATA:
                request = self.requests.get(stream)
                if request is not None:
                    body = request["request_body" if sender == 0 else "body"]
                    if len(body) + len(payload) <= LIMIT:
                        body += payload

    def settings(self, sender, payload):
        at = 0
        while (name := varint(payload, at)) and (value := varint(payload, name[1])):
            self.sides[sender].settings[name[0]] = value[0]
            at = value[1]

    def headers(self, key, sender, payload=None, resume=False):
        stream = key[0]
        decoder = self.decoder(sender)
        try:
            _, headers = decoder.resume_header(stream) if resume else decoder.feed_header(stream, payload)
        except pylsqpack.StreamBlocked:
            self.blocked[(stream, sender)] = key
            if sender == 0 and stream not in self.requests:
                self.requests[stream] = self.record(key, waiting=True)
            return
        except pylsqpack.DecompressionFailed as e:
            self.notes.append(f"{self.flow} stream {stream}: headers that do not decode: {e}")
            return
        said = [(name.decode("latin1"), value.decode("latin1")) for name, value in headers]
        request = self.requests.get(stream)
        if sender == 0 and request is None:
            self.requests[stream] = self.record(key, said)
        elif sender == 0 and request["waiting"]:
            request["request_headers"], request["waiting"] = said, False
        elif sender == 0:
            request["request_trailers"] += said
        else:
            if request is None:
                # The request went as early data, which keys found after the handshake do not open, and only its answer is here.
                request = self.requests[stream] = self.record(key, early=True)
            status = dict(said).get(":status", "")
            # An answer of 1xx comes before the real one and does not count as it.
            if not request["headers"] and not status.startswith("1"):
                state = self.streams[key]
                request["headers"], request["answered"] = said, state.get("last", state["first"])
            elif request["headers"]:
                request["trailers"] += said

    def record(self, key, said=(), early=False, waiting=False):
        """A request, from the moment its headers came, or its answer's when only that is here."""
        state = self.streams[key]
        return {"stream": key[0], "frame": state.get("last_frame", state["frame"]), "time": state.get("last", state["first"]),
                "request_headers": list(said), "request_body": bytearray(), "headers": [], "body": bytearray(), "answered": None, "trailers": [],
                "request_trailers": [],
                "early": early, "waiting": waiting}


def main():
    given = json.load(sys.stdin)
    out, notes = [], []
    for each in given["connections"]:
        connection = Connection(each["flow"])
        for when, frame, sender, stream, offset, data, fin in each["events"]:
            connection.take((when, frame, sender, stream, offset, base64.b64decode(data), fin))
        for stream, request in sorted(connection.requests.items()):
            asked = dict(request["request_headers"])
            if asked:
                url = f"{asked.get(':scheme', 'https')}://{asked.get(':authority', '?')}{asked.get(':path', '')}"
            else:
                url = "(asked in early data)" if request["early"] else "(its headers need table entries sent as early data)"
            took = request["answered"] - request["time"] if request["answered"] is not None and not request["early"] else None
            out.append({"id": f"h{request['frame']}.{stream}", "flow": connection.flow, "time": request["time"],
                        "method": asked.get(":method", "?"), "url": url,
                        "request_headers": request["request_headers"], "headers": request["headers"], "trailers": request["trailers"],
                        "request_trailers": request["request_trailers"],
                        "request_body": base64.b64encode(request["request_body"]).decode(), "body": base64.b64encode(request["body"]).decode(),
                        "took": took})
        waiting = sum(1 for _, sender in connection.blocked if sender == 0)
        if waiting:
            notes.append(f"{connection.flow}: the headers of {waiting} requests need table entries the client sent as early data, "
                         "which keys found after the handshake do not open")
        notes += connection.notes
        notes += [f"{connection.flow} stream {stream}: the answer's headers still wait on the table" for stream, sender in connection.blocked if sender == 1]
    json.dump({"requests": out, "notes": notes}, sys.stdout)


main()

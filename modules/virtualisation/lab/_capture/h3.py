"""The requests of HTTP/3 in QUIC's stream data, which guest-net hands over on standard input as JSON, and their answers,
written as JSON to standard output. It runs inside lab-box, since the guest chose every byte and ls-qpack, which
undoes the headers' compression, is C.

Each connection's stream data comes in the order of the packets, as chunks of a stream at an offset, and is put back
together per stream and per side. The unidirectional streams carry each side's settings and the instructions for its
headers' table, the bidirectional ones a request and its answer as HTTP/3 frames.

A connection guest-net read only from a key update on, with the secrets after it, misses the start of the streams that
carry the tables, so what a header block takes from a table filled before the update is left unread and the rest of it
read. A side that opened its encoder stream only after the update, at its first entry, has all of its table here. The entries an encoder added after the update are read from its stream, and placed by how many came before, which
the header blocks tell, as Late says.
"""
import base64
import bisect
import collections
import json
import re
import sys

import pylsqpack

LIMIT = 64 << 20
# What stands for a header whose name and value, or whose name, were in a table filled before the key update read from:
# a literal name of QPACK (RFC 9204 4.5.6), and a value after it.
UNREAD_NAME = b"\x21?"
UNREAD = UNREAD_NAME + bytes([23]) + b"(set before the update)"
# The entries of QPACK's static table (RFC 9204 Appendix A).
STATIC = 99
# Table sizes a side may have allowed the other, which a connection read from a key update on does not show, since SETTINGS
# come first: those of browsers and libraries. A count before the update is taken when this many blocks vote, and this
# share of them for it.
CAPACITIES = (65536, 32768, 16384, 8192, 4096, 2048, 1024)
VOTERS, MAJORITY = 3, 2 / 3
# How far into an encoder stream read from a key update on its first instruction may begin, and by how many inserts the
# reading taken has to have more than one that disagrees with it, when it begins at the start of the first piece, where
# most do, and past it, where readings from within the instruction the piece began in compete with it.
WINDOW, LEAD, LEAD_PAST = 4096, 1, 3
# How much of such a stream is read.
TABLE_LIMIT = 1 << 20
# A header's name as HTTP/3 allows it, lower case (RFC 9114 4.2, RFC 9110 5.6.2), and what its value may not hold (RFC
# 9110 5.5).
NAME = re.compile(rb"[!#$%&'*+.^_`|~0-9a-z-]+|:[a-z]+")
FORBIDDEN = re.compile(rb"[\x00-\x08\x0a-\x1f\x7f]")
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


def string_end(data, at):
    """Where a string of QPACK that begins at this offset ends, past its Huffman bit and its length, or None."""
    length = prefixed(data, at, 7)
    if length is None or length[1] + length[0] > len(data):
        return None
    return length[1] + length[0]


def without_table(block):
    """A header block of QPACK with what it takes from the dynamic table left as headers named ?, so that it decodes without
    one, or None when it does not parse. A literal value whose name was in the table keeps its value."""
    count = prefixed(block, 0, 8)
    base = count and prefixed(block, count[1], 7)
    if not base:
        return None
    out, at = bytearray(b"\x00\x00"), base[1]
    while at < len(block):
        byte = block[at]
        if byte & 0x80:
            # An entry by index, of the static table when its T bit is set.
            end = prefixed(block, at, 6)
            if end is None:
                return None
            out += block[at: end[1]] if byte & 0x40 else UNREAD
            at = end[1]
        elif byte & 0x40:
            # A literal value after a name by index, of the static table when its T bit is set.
            name = prefixed(block, at, 4)
            end = name and string_end(block, name[1])
            if not end:
                return None
            out += block[at: end] if byte & 0x10 else UNREAD_NAME + block[name[1]: end]
            at = end
        elif byte & 0x20:
            name = prefixed(block, at, 3)
            end = name and name[1] + name[0] <= len(block) and string_end(block, name[1] + name[0])
            if not end:
                return None
            out += block[at: end]
            at = end
        elif byte & 0x10:
            end = prefixed(block, at, 4)
            if end is None:
                return None
            out += UNREAD
            at = end[1]
        else:
            name = prefixed(block, at, 3)
            end = name and string_end(block, name[1])
            if not end:
                return None
            out += UNREAD_NAME + block[name[1]: end]
            at = end
    return bytes(out)


def encoded(value, bits, flags):
    """An integer of QPACK with a prefix of this many bits, after the flags of its first byte (RFC 7541 5.1)."""
    mask = (1 << bits) - 1
    if value < mask:
        return bytes([flags | value])
    out, value = bytearray([flags | mask]), value - mask
    while value >= 0x80:
        out.append(value & 0x7F | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def instruction(data, at):
    """The instruction of an encoder stream at this offset, as (where it ends, what it is): ("insert", name, value), the
    name ("static", index), ("literal", Huffman, bytes) or ("dynamic", relative index) and the value the string's own
    bytes with its Huffman bit and length, ("duplicate", relative index) or ("capacity", size). False when the data ends
    within it, and None when it is none."""
    byte = data[at]
    if byte & 0x80:
        index = prefixed(data, at, 6)
        if index and byte & 0x40 and index[0] >= STATIC:
            return None
        end = index and string_end(data, index[1])
        return (end, ("insert", ("static" if byte & 0x40 else "dynamic", index[0]), bytes(data[index[1]: end]))) if end else False
    if byte & 0x40:
        length = prefixed(data, at, 5)
        name = length and length[1] + length[0]
        end = name and name <= len(data) and string_end(data, name)
        return (end, ("insert", ("literal", bool(byte & 0x20), bytes(data[length[1]: name])), bytes(data[name: end]))) if end else False
    if byte & 0x20:
        size = prefixed(data, at, 5)
        if size is None:
            return False
        return (size[1], ("capacity", size[0])) if size[0] <= CAPACITIES[0] else None
    index = prefixed(data, at, 5)
    return (index[1], ("duplicate", index[0])) if index else False


def literal(name, value):
    """A field line of a literal of QPACK with the name of an insert, or ? for one not known, and this value."""
    if name is None:
        return UNREAD_NAME + value
    if name[0] == "static":
        return encoded(name[1], 4, 0x50) + value
    return encoded(len(name[2]), 3, 0x20 | (0x08 if name[1] else 0)) + name[2] + value


def allowed(insert, decoder):
    """Whether an insert gives a header HTTP/3 allows (RFC 9114 4.2, RFC 9110 5.5), its name too unless it is taken from
    the table."""
    dynamic = insert[1][0] == "dynamic"
    try:
        _, ((name, value),) = decoder.feed_header(0, b"\x00\x00" + literal(None if dynamic else insert[1], insert[2]))
    except (pylsqpack.DecompressionFailed, ValueError):
        return False
    return (dynamic or NAME.fullmatch(name) is not None) and not FORBIDDEN.search(value)


def threaded(data, decoder):
    """The instructions of an encoder stream whose first piece may begin within one, as (where each ends, what it is),
    from the first that can be told. Reading from there, or from within any later one, gives instructions too until it
    falls into step with the real ones, but its inserts seldom give headers HTTP/3 allows. So of the readings from each
    place in the first WINDOW bytes that last to the end, the one with the most inserts is taken, from where each other
    with almost as many joined it, and none when one of those never does. One that begins past the start may begin with
    an insert read from the end of the instruction the piece began in, which ends where the real ones begin, so that one
    is left out."""
    # Where the instruction at each place a reading went ends, False where the data ends within it and None where it is
    # none, kept small since a hostile guest can fill the stream with instructions of a byte.
    data, after, inserting, inserts = data[:TABLE_LIMIT], {}, set(), {}
    for start in range(min(len(data), WINDOW)):
        at = start
        while at < len(data) and at not in after:
            step = instruction(data, at)
            # Encoders set the table's capacity once, at the start, before any update.
            if step and (step[1][0] == "capacity" or step[1][0] == "insert" and not allowed(step[1], decoder)):
                step = None
            after[at] = step and step[0]
            if step and step[1][0] == "insert":
                inserting.add(at)
            at = step[0] if step else len(data)
    for at in sorted(after, reverse=True):
        end = after[at]
        rest = None if end is None else 0 if end is False or end >= len(data) else inserts[end]
        inserts[at] = None if rest is None else rest + (at in inserting)
    lasting = [start for start in range(min(len(data), WINDOW)) if inserts[start] is not None]
    if not lasting:
        return []
    best = max(lasting, key=lambda start: (inserts[start], -start))
    on, at = set(), best
    while at < len(data) and after[at]:
        on.add(at)
        at = after[at]
    on.add(at)
    joins = {}
    for at in sorted(after, reverse=True):
        joins[at] = at if at in on else joins.get(after[at]) if after[at] else None
    begin = best
    for start in lasting:
        if start not in on and inserts[best] - inserts[start] < (LEAD_PAST if best else LEAD):
            if joins[start] is None:
                return []
            begin = max(begin, joins[start])
    if begin == best > 0 and after[begin]:
        begin = after[begin]
    out, at = [], begin
    while at < len(data) and after[at]:
        out.append(instruction(data, at))
        at = after[at]
    return out


def required(count, most, total):
    """A header block's Required Insert Count from its encoded one, the table's most entries and how many were added by
    then (RFC 9204 4.5.1.1)."""
    if not count:
        return 0
    full, top = 2 * most, total + most
    value = top // full * full + count - 1
    return value - full if value > top else value


def joined(pieces, start):
    """The bytes of a stream from an offset on, as far as its pieces join, and the event each piece came in, by where it
    begins in them."""
    data, marks = bytearray(), []
    for offset in sorted(pieces):
        index, piece = pieces[offset]
        if offset < start or offset > start + len(data):
            if offset > start + len(data):
                break
            continue
        if offset + len(piece) > start + len(data):
            marks.append((len(data), index))
            data += piece[start + len(data) - offset:]
    return bytes(data), marks


def event_at(marks, position):
    found = bisect.bisect_right(marks, (position, float("inf"))) - 1
    return marks[found][1] if found >= 0 else -1


class Late:
    """One side's table of headers as far as a connection read from a key update on shows it: the entries its encoder added
    since, with the event each came in, and how many came before. Only the header blocks tell that count. An encoder
    mostly refers to an entry it has just added, so a block's Required Insert Count is then the count at that moment,
    and each block votes for the count before the update that this makes it: the one most blocks agree on is taken,
    for the table size that makes them agree most, and none when too few vote or agree."""

    def __init__(self, parsed, marks, before, capacity):
        self.before, self.most, self.entries, self.arrived = before, capacity // 32, [], []

        def entry(relative):
            # A relative index counts back from the newest entry when the instruction came, past those read here into the
            # ones from before the update.
            at = len(self.entries) - 1 - relative
            return self.entries[at] if at >= 0 else (None, None)

        for end, item in parsed:
            if item[0] == "duplicate":
                self.entries.append(entry(item[1]))
            elif item[0] == "insert":
                self.entries.append((entry(item[1][1])[0] if item[1][0] == "dynamic" else item[1], item[2]))
            else:
                continue
            self.arrived.append(event_at(marks, end - 1))
        self.arrived.sort()

    @staticmethod
    def found(events, sender):
        """The table of one side, from the events of a connection read from a key update on, or None."""
        pieces, blocks = {}, []
        for index, (_, _, side, stream, offset, data, _) in enumerate(events):
            if side == sender:
                pieces.setdefault(stream, {}).setdefault(offset, (index, data))
        for stream, parts in pieces.items():
            if stream & 0x2 or 0 not in parts:
                continue
            data, marks = joined(parts, 0)
            at = 0
            while (head := varint(data, at)) and (size := varint(data, head[1])) and size[1] + size[0] <= len(data):
                count = prefixed(data, size[1], 8) if head[0] == HEADERS else None
                if count and count[0]:
                    blocks.append((event_at(marks, at), count[0]))
                at = size[1] + size[0]
        best, decoder = None, pylsqpack.Decoder(0, 0)
        # Its encoder stream is one of the side's unidirectional streams that begin past their start.
        for stream, parts in pieces.items():
            if len(blocks) < VOTERS or not stream & 0x2 or 0 in parts:
                continue
            data, marks = joined(parts, min(parts))
            parsed = threaded(data, decoder)
            added = sorted(event_at(marks, end - 1) for end, item in parsed if item[0] in ("insert", "duplicate"))
            for capacity in CAPACITIES if added else ():
                full = 2 * (capacity // 32)
                # A count past twice the table's entries is one a table this size cannot have.
                if max(count for _, count in blocks) > full:
                    continue
                tally = collections.Counter((count - 1 - bisect.bisect_left(added, index)) % full for index, count in blocks)
                before, votes = tally.most_common(1)[0]
                if votes / len(blocks) >= MAJORITY and (best is None or votes > best[0]):
                    best = (votes, parsed, marks, before, capacity)
        return Late(*best[1:]) if best else None

    def line(self, absolute, value=None):
        """A field line of a literal for the entry at this absolute index, with its own value or the one given, or one named
        ? for an entry from before the update."""
        entry = self.entries[absolute - self.before] if 0 <= absolute - self.before < len(self.entries) else (None, None)
        value = entry[1] if value is None else value
        return UNREAD if value is None else literal(entry[0], value)

    def rewrite(self, block, position):
        """A header block with the entries it takes from the table written out as literals, so that it decodes without one,
        those from before the update named ?, or None when it does not parse."""
        count = prefixed(block, 0, 8)
        delta = count and prefixed(block, count[1], 7)
        if not delta:
            return None
        sure = required(count[0], self.most, self.before + bisect.bisect_left(self.arrived, position))
        base = sure - delta[0] - 1 if block[count[1]] & 0x80 else sure + delta[0]
        out, at = bytearray(b"\x00\x00"), delta[1]
        while at < len(block):
            byte = block[at]
            if byte & 0x80:
                index = prefixed(block, at, 6)
                if index is None:
                    return None
                out += block[at: index[1]] if byte & 0x40 else self.line(base - 1 - index[0])
                at = index[1]
            elif byte & 0x40:
                index = prefixed(block, at, 4)
                end = index and string_end(block, index[1])
                if not end:
                    return None
                out += block[at: end] if byte & 0x10 else self.line(base - 1 - index[0], block[index[1]: end])
                at = end
            elif byte & 0x20:
                name = prefixed(block, at, 3)
                end = name and name[1] + name[0] <= len(block) and string_end(block, name[1] + name[0])
                if not end:
                    return None
                out += block[at: end]
                at = end
            elif byte & 0x10:
                index = prefixed(block, at, 4)
                if index is None:
                    return None
                out += self.line(base + index[0])
                at = index[1]
            else:
                index = prefixed(block, at, 3)
                end = index and string_end(block, index[1])
                if not end:
                    return None
                out += self.line(base + index[0], block[index[1]: end])
                at = end
        return bytes(out)


class Side:
    """What one side of a connection said: its settings and its own table of headers, which only it fills. sized says
    whether the table's decoder was made with what the other side allowed."""

    def __init__(self):
        self.settings, self.decoder, self.sized = {}, None, False


class Connection:
    def __init__(self, flow, late=False, events=()):
        self.flow, self.sides, self.late = flow, (Side(), Side()), late
        self.streams, self.requests, self.blocked, self.notes = {}, {}, {}, []
        self.whole = {sender for _, _, sender, stream, offset, data, _ in events if late and stream & 0x2 and not offset and data[:1] == bytes([ENCODER])}
        self.tables = {sender: Late.found(events, sender) for sender in (0, 1) if sender not in self.whole} if late else {}
        self.position = 0

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
        bare = None
        if self.late and sender not in self.whole and not resume and (prefixed(payload, 0, 8) or (1,))[0]:
            # Its table was filled before the update the connection was read from, so a block that needs it decodes without,
            # with what was added since where that could be placed.
            table = self.tables.get(sender)
            bare = table.rewrite(payload, self.position) if table else without_table(payload)
            if bare is None:
                self.notes.append(f"{self.flow} stream {stream}: headers that do not parse")
                return
        try:
            if bare is not None:
                _, headers = pylsqpack.Decoder(0, 0).feed_header(stream, bare)
            else:
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
        events = [(when, frame, sender, stream, offset, base64.b64decode(data), fin) for when, frame, sender, stream, offset, data, fin in each["events"]]
        connection = Connection(each["flow"], bool(each.get("late")), events)
        for connection.position, event in enumerate(events):
            connection.take(event)
        for stream, request in sorted(connection.requests.items()):
            asked = dict(request["request_headers"])
            if asked:
                url = f"{asked.get(':scheme', 'https')}://{asked.get(':authority', '?')}{asked.get(':path', '')}"
            else:
                url = "(asked before the key update it was read from)" if request["early"] and connection.late else \
                    "(asked in early data)" if request["early"] else "(its headers need table entries sent as early data)"
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

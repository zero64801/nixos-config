"""TLS as a flow of the capture holds it: the two byte streams taken apart into the hellos and the first encrypted records,
which is what keys scan checks a candidate secret against. The bytes are the guest's, so every length is checked first."""
import struct

CHANGE_CIPHER_SPEC, HANDSHAKE, APPLICATION_DATA = 20, 22, 23
CLIENT_HELLO, SERVER_HELLO, FINISHED = 1, 2, 20
# The random of a ServerHello that is a HelloRetryRequest, from RFC 8446 4.1.3.
RETRY = bytes.fromhex("CF21AD74E59A6111BE1D8C021E65B891C2A211167ABB8C5E079E09E2C8A8339C")
SERVER_NAME, SUPPORTED_VERSIONS, ENCRYPT_THEN_MAC, EARLY_DATA = 0x0000, 0x002B, 0x0016, 0x002A
# Encrypted records kept each way: TLS 1.3 servers send their handshake in up to four records before the first one under
# the traffic secret.
KEPT = 8
LARGEST = (1 << 14) + 2048


class Session:
    """What keys scan needs of one flow: the randoms, the version and suite chosen, and the encrypted records each way."""

    def __init__(self):
        self.client_random = self.server_random = b""
        self.version = self.suite = 0
        self.etm = self.early = False
        self.name, self.quic = "", 0
        self.records = []
        # For a session of the newest keys after key updates: for each direction, how many updates came before each record.
        self.epochs = None

    def __repr__(self):
        return f"Session(TLS {self.version:#06x} suite {self.suite:#06x}, {len(self.records)} records)"


def records(data):
    """The records of one direction, as (type, version, body), up to the first that is not whole or not a record."""
    at = 0
    while at + 5 <= len(data):
        kind, version, length = data[at], struct.unpack_from(">H", data, at + 1)[0], struct.unpack_from(">H", data, at + 3)[0]
        if kind not in (20, 21, 22, 23, 24) or version >> 8 != 3 or length > LARGEST or at + 5 + length > len(data):
            return
        yield kind, version, data[at + 5: at + 5 + length]
        at += 5 + length


def messages(found):
    """The handshake messages carried in plaintext by the leading records of one direction, as (type, body)."""
    buffer = b""
    for kind, _, body in found:
        if kind == CHANGE_CIPHER_SPEC:
            continue
        if kind != HANDSHAKE:
            return
        buffer += body
        while len(buffer) >= 4:
            length = int.from_bytes(buffer[1:4], "big")
            if len(buffer) < 4 + length:
                break
            yield buffer[0], buffer[4: 4 + length]
            buffer = buffer[4 + length:]


def extensions(body, at):
    """The extensions of a hello from the offset where their length is, as {type: data}."""
    if at + 2 > len(body):
        return {}
    end = min(len(body), at + 2 + struct.unpack_from(">H", body, at)[0])
    at += 2
    found = {}
    while at + 4 <= end:
        kind, length = struct.unpack_from(">HH", body, at)
        found[kind] = body[at + 4: at + 4 + length]
        at += 4 + length
    return found


def client_hello(body):
    """The client random and the extensions of a ClientHello, or None."""
    if len(body) < 39:
        return None
    at = 34 + 1 + body[34]
    if at + 2 > len(body):
        return None
    at += 2 + struct.unpack_from(">H", body, at)[0]
    if at + 1 > len(body):
        return None
    at += 1 + body[at]
    return body[2:34], extensions(body, at)


def server_hello(body):
    """The version, server random, suite and extensions of a ServerHello, or None."""
    if len(body) < 38:
        return None
    at = 34 + 1 + body[34]
    if at + 3 > len(body):
        return None
    suite = struct.unpack_from(">H", body, at)[0]
    found = extensions(body, at + 3)
    version = struct.unpack_from(">H", body, 0)[0]
    if len(found.get(SUPPORTED_VERSIONS, b"")) == 2:
        version = struct.unpack(">H", found[SUPPORTED_VERSIONS])[0]
    return version, body[2:34], suite, found


def session(client, server):
    """A flow's TLS from what the client and the server sent, or None when it is no handshake of TLS 1.0 to 1.3."""
    sent, got = list(records(client)), list(records(server))
    hello = next((client_hello(body) for kind, body in messages(sent) if kind == CLIENT_HELLO), None)
    if not hello:
        return None
    chosen = None
    for kind, body in messages(got):
        if kind == SERVER_HELLO:
            parsed = server_hello(body)
            if parsed and parsed[1] != RETRY:
                chosen = parsed
                break
    if not chosen or chosen[0] not in (0x0301, 0x0302, 0x0303, 0x0304):
        return None
    found = Session()
    found.client_random, (found.version, found.server_random, found.suite, accepted) = hello[0], chosen
    found.etm = ENCRYPT_THEN_MAC in hello[1] and ENCRYPT_THEN_MAC in accepted
    found.early = EARLY_DATA in hello[1]
    found.name = server_name(hello[1])
    for direction, stream in ((0, sent), (1, got)):
        kept = encrypted(stream, found.version)
        if found.version == 0x0304:
            # What follows a KeyUpdate is under a newer secret, which opens the next record at sequence number 0 too and must
            # not be taken for the first.
            cut = next((n for n, (_, _, body) in enumerate(kept) if len(body) == update_size(found.suite)), None)
            kept = kept if cut is None else kept[: cut + 1]
        found.records += [(direction, kind, version, body) for kind, version, body in kept]
    return found


def update_size(suite):
    """How long a record that carries a KeyUpdate is when not padded: the message of 5 bytes, the inner type and the tag."""
    return 6 + (8 if suite == 0x1305 else 16)


def updates(data, suite):
    """The encrypted records of one direction of TLS 1.3 with where each begins, (offset, record), and how many of them are
    the size of a KeyUpdate, which only that message is, unpadded, once the handshake is done."""
    found, at, count = [], 0, 0
    while at + 5 <= len(data):
        kind, length = data[at], struct.unpack_from(">H", data, at + 3)[0]
        if kind not in (20, 21, 22, 23, 24) or data[at + 1] != 3 or length > LARGEST or at + 5 + length > len(data):
            break
        if kind == APPLICATION_DATA:
            found.append((at, data[at: at + 5 + length]))
            count += length == update_size(suite)
        at += 5 + length
    return found, count


# A record this short may be a KeyUpdate padded to a small block, and the last records of a direction may follow one padded more.
SMALL, TAIL, LATE = 256, 4, 15


def starts(found, data, normal, broad=False, wide=False):
    """Where the newest secret of one direction of TLS 1.3 may begin, as (record, how many updates came before it), newest
    first and LATE at most, past the first normal records, which the session of the first keys has. The record after one
    the size of a KeyUpdate is surely such a start, with the count exact. With broad also the record after each short
    one and the last records, for KeyUpdates sent padded, with the count a least. With wide every one of the last records
    too, for KeyUpdates padded more than a short record is long."""
    kept, _ = updates(data, found.suite)
    size = update_size(found.suite)
    before, count = [], 0
    for _, record in kept:
        before.append(count)
        count += len(record) - 5 == size
    chosen, out = set(), []

    def take(index, updates_before):
        if normal <= index < len(kept) and index not in chosen and len(out) < LATE:
            chosen.add(index)
            out.append((kept[index][1], updates_before))

    for index in range(len(kept) - 1, 0, -1):
        if len(kept[index - 1][1]) - 5 == size:
            take(index, before[index])
    if broad:
        for index in range(len(kept) - 1, 0, -1):
            if len(kept[index - 1][1]) - 5 <= SMALL:
                take(index, before[index] + 1)
        for index in range(len(kept) - 1, max(len(kept) - 1 - (LATE if wide else TAIL), 0), -1):
            take(index, before[index] + 1)
    return out


def late(found, client, server, broad=False, wide=False):
    """A session of the newest keys of a TLS 1.3 connection that updated its keys, whose secrets are the only ones its
    program still holds: per direction, the records its newest secret may begin at, each at sequence number 0. None when
    there is no such record."""
    if found.version != 0x0304 or found.quic:
        return None
    newer = Session()
    newer.client_random, newer.version, newer.suite, newer.name, newer.epochs = found.client_random, 0x0304, found.suite, found.name, {0: [], 1: []}
    for direction, data in ((0, client), (1, server)):
        normal = sum(1 for side, *_ in found.records if side == direction)
        for record, updates_before in starts(found, data, normal, broad, wide):
            newer.records.append((direction, APPLICATION_DATA, struct.unpack_from(">H", record, 1)[0], record[5:]))
            newer.epochs[direction].append(updates_before)
    return newer if newer.records else None


def encrypted(stream, version):
    """The first encrypted records of one direction: in TLS 1.3 those of type application data, before it the one after
    the ChangeCipherSpec, which is the Finished."""
    if version == 0x0304:
        return [(kind, v, body) for kind, v, body in stream if kind == APPLICATION_DATA][:KEPT]
    for at, (kind, _, _) in enumerate(stream):
        if kind == CHANGE_CIPHER_SPEC:
            return stream[at + 1: at + 2]
    return []


def label(found, direction, index, inner, first):
    """The key log label of a secret that opened the record at this index of this direction at sequence number 0, or for
    QUIC the packet of this kind. A session of the newest keys names them by how many updates came before. A QUIC packet
    tells only whether that many was odd or even, by its key phase, which comes as first, so it names the least."""
    if found.epochs:
        if found.quic:
            return f"{'SERVER' if direction == 1 else 'CLIENT'}_TRAFFIC_SECRET_{1 if first else 2}"
        return f"{'SERVER' if direction == 1 else 'CLIENT'}_TRAFFIC_SECRET_{found.epochs[direction][index]}"
    if found.quic:
        side = "SERVER" if direction == 1 else "CLIENT"
        if inner == EARLY_PACKET:
            return "CLIENT_EARLY_TRAFFIC_SECRET"
        return f"{side}_TRAFFIC_SECRET_0" if inner == SHORT_PACKET else f"{side}_HANDSHAKE_TRAFFIC_SECRET"
    if found.version != 0x0304:
        return "CLIENT_RANDOM"
    if direction == 1:
        return "SERVER_HANDSHAKE_TRAFFIC_SECRET" if index == 0 else "SERVER_TRAFFIC_SECRET_0"
    if inner == HANDSHAKE and first == FINISHED:
        return "CLIENT_HANDSHAKE_TRAFFIC_SECRET"
    return "CLIENT_EARLY_TRAFFIC_SECRET" if found.early and index == 0 else "CLIENT_TRAFFIC_SECRET_0"


# QUIC's versions 1 (RFC 9000) and 2 (RFC 9369), and what the two type bits of a long header mean in each.
QUIC_VERSIONS = {0x00000001: 1, 0x6B3343CF: 2}
LONG_TYPES = {1: {0: "initial", 1: "early", 2: "handshake", 3: "retry"}, 2: {1: "initial", 2: "early", 3: "handshake", 0: "retry"}}
EARLY_PACKET, HANDSHAKE_PACKET, SHORT_PACKET, LATE_PACKET = 1, 2, 3, 4


def varint(data, at):
    """A variable length integer of QUIC (RFC 9000 16) and where it ends."""
    if at >= len(data):
        raise IndexError
    size = 1 << (data[at] >> 6)
    if at + size > len(data):
        raise IndexError
    value = data[at] & 0x3F
    for i in range(1, size):
        value = value << 8 | data[at + i]
    return value, at + size


def quic_packets(datagram, short_cid):
    """The packets coalesced in a datagram, as (kind, version, where the packet number starts, the packet, its destination
    and source connection IDs), up to the first that does not parse. A short header packet runs to the datagram's end and
    has a destination ID of the length the connection chose."""
    at = 0
    while at < len(datagram):
        first = datagram[at]
        if not first & 0x80:
            if short_cid is None or at + 1 + short_cid >= len(datagram):
                return
            destination, end = datagram[at + 1: at + 1 + short_cid], len(datagram)
            # What the guest's network card sends in one batch, as GSO does, is several datagrams of the same connection
            # back to back, and the next starts where its ID is again after a first byte of a short header.
            if short_cid >= 4:
                found = datagram.find(destination, at + 21)
                while found != -1 and datagram[found - 1] & 0xC0 != 0x40:
                    found = datagram.find(destination, found + 1)
                if found != -1:
                    end = found - 1
            yield "short", None, 1 + short_cid, datagram[at:end], destination, b""
            at = end
            continue
        try:
            version = QUIC_VERSIONS.get(int.from_bytes(datagram[at + 1: at + 5], "big"))
            if version is None:
                return
            kind = LONG_TYPES[version][(first >> 4) & 3]
            pos = at + 5
            destination = datagram[pos + 1: pos + 1 + datagram[pos]]
            pos += 1 + datagram[pos]
            source = datagram[pos + 1: pos + 1 + datagram[pos]]
            pos += 1 + datagram[pos]
            if kind == "retry":
                return
            if kind == "initial":
                token, pos = varint(datagram, pos)
                pos += token
            length, pos = varint(datagram, pos)
        except IndexError:
            return
        if pos + length > len(datagram) or length < 20:
            return
        yield kind, version, pos - at, datagram[at: pos + length], destination, source
        at = pos + length


def server_name(found):
    """The name a ClientHello's extensions asked for, or an empty one."""
    named = found.get(SERVER_NAME, b"")
    if len(named) > 5 and named[2] == 0:
        return named[5: 5 + int.from_bytes(named[3:5], "big")].decode("ascii", "replace")
    return ""


def quic_session(datagrams, client_random, suite, name=""):
    """A QUIC connection's session from its datagrams in order, as (0 from the client or 1 from the server, bytes), with the
    client random and the suite tshark read from the Initial packets it can open, or None."""
    found, ids, version = Session(), [None, None], None
    found.version, found.suite, found.client_random, found.quic, found.name = 0x0304, suite, client_random, 0, name
    kept = {(side, kind): 0 for side in (0, 1) for kind in (EARLY_PACKET, HANDSHAKE_PACKET, SHORT_PACKET)}
    for side, datagram in datagrams:
        # A short header carries the ID its receiver chose: the server's in what the client sends, and the other way.
        for kind, packet_version, at, packet, _, source in quic_packets(datagram, None if ids[1 - side] is None else len(ids[1 - side])):
            if packet_version:
                version = version or packet_version
                if ids[side] is None and kind in ("initial", "handshake"):
                    ids[side] = source
            code = {"early": EARLY_PACKET, "handshake": HANDSHAKE_PACKET, "short": SHORT_PACKET}.get(kind)
            # Only a client sends early data, and a few of its packets are as many as a check needs.
            if code and kept[(side, code)] < (KEPT if code == SHORT_PACKET else 4) and (side == 0 or code != EARLY_PACKET):
                kept[(side, code)] += 1
                found.records.append((side, code, at, packet))
    if not version or not found.records:
        return None
    found.quic = version
    return found


def quic_short_packets(datagrams):
    """The short packets of a QUIC connection's datagrams in order, each as (0 from the client or 1 from the server, the least
    packet number it can have, where its number starts, the packet, what else came with its datagram). The least number
    is its place among the packets its side sent in the application's numbers, which early data begins (RFC 9000 12.3).
    Numbers a sender skipped and packets lost before the guest put the real one higher."""
    ids, counts = [None, None], [0, 0]
    for side, datagram, *extra in datagrams:
        for kind, version, at, packet, _, source in quic_packets(datagram, None if ids[1 - side] is None else len(ids[1 - side])):
            if version and ids[side] is None and kind in ("initial", "handshake"):
                ids[side] = source
            if kind == "short":
                yield side, counts[side], at, packet, extra
            if kind in ("short", "early"):
                counts[side] += 1


# A session of QUIC's newest keys has a few of the last short packets of each direction, the smallest, which open fastest.
LATE_LAST, LATE_PICKED = 12, 2


def quic_late(datagrams, found, sides=(0, 1)):
    """A session of the newest keys of a QUIC connection, whose secrets after key updates are the only ones its program still
    holds: for each direction of sides, a few of its last short packets, each with the least packet number it can have.
    No packet shows where the keys were updated, since the key phase bit is under the header's protection, whose key
    only the first secret gives. None when there is no such packet."""
    newer, shorts = Session(), ([], [])
    newer.client_random, newer.version, newer.suite, newer.name, newer.quic = found.client_random, 0x0304, found.suite, found.name, found.quic
    newer.epochs = {0: [], 1: []}
    for side, lowest, at, packet, _ in quic_short_packets(datagrams):
        shorts[side].append((lowest, at, packet))
    for side in sides:
        for lowest, at, packet in sorted(shorts[side][-LATE_LAST:], key=lambda short: len(short[2]))[:LATE_PICKED]:
            newer.records.append((side, LATE_PACKET, at, packet, lowest))
    return newer if newer.records else None


def crypto_frames(plain):
    """The CRYPTO frames of an Initial packet's plaintext, as (offset, data), up to the first frame this cannot step over."""
    found, at = [], 0
    try:
        while at < len(plain):
            kind = plain[at]
            if kind in (0x00, 0x01):
                at += 1
            elif kind in (0x02, 0x03):
                # Largest acknowledged, delay, how many more ranges, the first range, then a gap and a length for each more.
                _, at = varint(plain, at + 1)
                _, at = varint(plain, at)
                ranges, at = varint(plain, at)
                _, at = varint(plain, at)
                for _ in range(2 * ranges + (3 if kind == 0x03 else 0)):
                    _, at = varint(plain, at)
            elif kind == 0x06:
                offset, at = varint(plain, at + 1)
                length, at = varint(plain, at)
                found.append((offset, plain[at: at + length]))
                at += length
            else:
                break
    except IndexError:
        pass
    return found


def quic_crypto(datagrams, opener):
    """What each side sent in the CRYPTO frames of its Initial packets, which opener opens as (packet, where its number
    starts, version, the client's first destination ID, from the server), as far as it is contiguous, read as handshake
    messages."""
    original, pieces = None, ([], [])
    for side, datagram in datagrams:
        for kind, version, at, packet, destination, _ in quic_packets(datagram, None):
            if kind != "initial":
                continue
            if original is None and side == 0:
                original = destination
            if original is None:
                continue
            plain = opener(packet, at, version, original, side == 1)
            if plain:
                pieces[side].extend(crypto_frames(plain))
    hellos = []
    for side, frames in enumerate(pieces):
        data, expected = bytearray(), 0
        for offset, chunk in sorted(frames, key=lambda frame: frame[0]):
            if offset > expected:
                break
            if offset + len(chunk) > expected:
                data += chunk[expected - offset:]
                expected = offset + len(chunk)
        hellos.append(list(messages([(HANDSHAKE, 0x0303, bytes(data))])))
    return hellos


def quic_client_hello(datagrams, opener):
    """The client random and the name asked for of a QUIC connection from the client's Initial packets alone, which is all
    there is while it sends early data, or None."""
    hello = next((client_hello(body) for kind, body in quic_crypto(datagrams, opener)[0] if kind == CLIENT_HELLO), None)
    return (hello[0], server_name(hello[1])) if hello else None


def quic_hellos(datagrams, opener):
    """The client random and the suite of a QUIC connection, read from the hellos in its Initial packets, or None."""
    hellos = quic_crypto(datagrams, opener)
    hello = next((client_hello(body) for kind, body in hellos[0] if kind == CLIENT_HELLO), None)
    answer = next((server_hello(body) for kind, body in hellos[1] if kind == SERVER_HELLO), None)
    if not hello or not answer:
        return None
    return hello[0], answer[2], server_name(hello[1])

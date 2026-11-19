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
        self.name = ""
        self.records = []

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
    named = hello[1].get(SERVER_NAME, b"")
    if len(named) > 5 and named[2] == 0:
        found.name = named[5: 5 + int.from_bytes(named[3:5], "big")].decode("ascii", "replace")
    for direction, stream in ((0, sent), (1, got)):
        found.records += [(direction, kind, version, body) for kind, version, body in encrypted(stream, found.version)]
    return found


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
    """The key log label of a secret that opened the record at this index of this direction at sequence number 0."""
    if found.version != 0x0304:
        return "CLIENT_RANDOM"
    if direction == 1:
        return "SERVER_HANDSHAKE_TRAFFIC_SECRET" if index == 0 else "SERVER_TRAFFIC_SECRET_0"
    if inner == HANDSHAKE and first == FINISHED:
        return "CLIENT_HANDSHAKE_TRAFFIC_SECRET"
    return "CLIENT_EARLY_TRAFFIC_SECRET" if found.early and index == 0 else "CLIENT_TRAFFIC_SECRET_0"

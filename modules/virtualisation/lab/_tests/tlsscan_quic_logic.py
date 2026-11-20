"""keys scan's search on real QUIC: aioquic's client talks to its server through a relay that keeps every datagram, in each
cipher of TLS 1.3 and in QUIC versions 1 and 2, and the secrets of the client's own key log are hidden in made up
memory among noise. The scanner has to find each where it was put, name it as aioquic did, and find nothing else.

It also has curl, on ngtcp2, talk HTTP/3 to aioquic's server, whose hellos have to be read from its Initial packets
alone, and two datagrams sent in one batch, as a network card does with GSO, taken apart again.

usage: tlsscan_quic_logic.py CAPTURE_CODE LIBTLSSCAN CURL_OF_HTTP3"""
import asyncio
import os
import random
import socket
import ssl
import subprocess
import sys
import threading

from aioquic.asyncio import connect, serve
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.packet import QuicProtocolVersion
from aioquic.tls import CipherSuite

sys.path.insert(0, sys.argv[1])
import scan
import tlsrecords

scanner = scan.Scanner(sys.argv[2])
subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", "key.pem",
                "-out", "cert.pem", "-days", "1", "-subj", "/CN=localhost"], check=True, capture_output=True)


class Relay:
    """Passes the datagrams of one client on to the server and keeps each, in order, with the side that sent it."""

    def __init__(self, server):
        self.kept, self.client = [], None
        self.outside = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.outside.bind(("127.0.0.1", 0))
        self.port = self.outside.getsockname()[1]
        self.inside = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.inside.connect(("127.0.0.1", server))
        threading.Thread(target=self.out_to_in, daemon=True).start()
        threading.Thread(target=self.in_to_out, daemon=True).start()

    def out_to_in(self):
        while True:
            data, self.client = self.outside.recvfrom(65536)
            self.kept.append((0, data))
            self.inside.send(data)

    def in_to_out(self):
        while True:
            data = self.inside.recv(65536)
            self.kept.append((1, data))
            if self.client:
                self.outside.sendto(data, self.client)


async def handle(reader, writer):
    asked = await reader.read()
    writer.write(b"answer to " + asked)
    writer.write_eof()


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def talk(suite, version, keys, token=b""):
    server_configuration = QuicConfiguration(alpn_protocols=["test"], is_client=False, cipher_suites=[suite], supported_versions=[version])
    server_configuration.load_cert_chain("cert.pem", "key.pem")
    port = free_port()
    listener = await serve("127.0.0.1", port, configuration=server_configuration,
                           stream_handler=lambda reader, writer: asyncio.ensure_future(handle(reader, writer)))
    relay = Relay(port)
    client_configuration = QuicConfiguration(alpn_protocols=["test"], is_client=True, verify_mode=ssl.CERT_NONE, cipher_suites=[suite],
                                             supported_versions=[version], secrets_log_file=keys, token=token)
    async with connect("127.0.0.1", relay.port, configuration=client_configuration) as client:
        reader, writer = await client.create_stream()
        writer.write(b"a question")
        writer.write_eof()
        assert await reader.read() == b"answer to a question"
        await asyncio.sleep(0.2)
    listener.close()
    return relay.kept


CASES = [(suite, version) for version in (QuicProtocolVersion.VERSION_1, QuicProtocolVersion.VERSION_2)
         for suite in (CipherSuite.AES_128_GCM_SHA256, CipherSuite.AES_256_GCM_SHA384, CipherSuite.CHACHA20_POLY1305_SHA256)]
sessions, logs = [], []
for suite, version in CASES:
    with open("keys.log", "w") as keys:
        datagrams = asyncio.run(talk(suite, version, keys))
    with open("keys.log") as f:
        lines = [line.split() for line in f if line.strip() and not line.startswith("#")]
    written = {label: bytes.fromhex(secret) for label, _, secret in lines}
    # The hellos as follow reads them, from the Initial packets alone, have to agree with aioquic's key log and suite.
    assert tlsrecords.quic_hellos(datagrams, scanner.quic_initial) == (bytes.fromhex(lines[0][1]), int(suite), ""), (suite, version)
    found = tlsrecords.quic_session(datagrams, bytes.fromhex(lines[0][1]), int(suite))
    assert found and found.quic == (1 if version == QuicProtocolVersion.VERSION_1 else 2), (suite, version, found)
    assert scanner.supported(found), (suite, version)
    kinds = {(side, kind) for side, kind, _, _ in found.records}
    assert {(0, 2), (1, 2), (0, 3), (1, 3)} <= kinds, (suite, version, kinds)
    sessions.append(found)
    logs.append(written)
print(f"{len(sessions)} QUIC connections of aioquic recorded")

# A client that comes back sends the server's token in its Initial packets, as Edge does, which puts their packet number
# far past where a header without one ends.
with open("keys.log", "w") as keys:
    datagrams = asyncio.run(talk(CipherSuite.AES_128_GCM_SHA256, QuicProtocolVersion.VERSION_1, keys, token=os.urandom(150)))
with open("keys.log") as f:
    opened_by = bytes.fromhex(next(line.split()[1] for line in f if line.strip() and not line.startswith("#")))
assert tlsrecords.quic_hellos(datagrams, scanner.quic_initial) == (opened_by, 0x1301, ""), "the hellos of a client with a token were not read"
print("the hellos of a client that sends a token are read")


async def curl(keys):
    """curl's HTTP/3 to a server that takes the handshake and the client's streams and keeps them, without an answer."""
    configuration = QuicConfiguration(alpn_protocols=["h3"], is_client=False)
    configuration.load_cert_chain("cert.pem", "key.pem")
    port, streams = free_port(), []
    listener = await serve("127.0.0.1", port, configuration=configuration, stream_handler=lambda reader, writer: streams.append((reader, writer)))
    relay = Relay(port)
    process = await asyncio.create_subprocess_exec(sys.argv[3], "-sk", "--http3-only", "--max-time", "3", f"https://localhost:{relay.port}/",
                                                   env=dict(os.environ, SSLKEYLOGFILE=keys))
    await process.wait()
    listener.close()
    return relay.kept


datagrams = asyncio.run(curl("curl.log"))
with open("curl.log") as f:
    lines = [line.split() for line in f if line.strip() and not line.startswith("#")]
written = {label: bytes.fromhex(secret) for label, _, secret in lines}
read = tlsrecords.quic_hellos(datagrams, scanner.quic_initial)
assert read and read[0] == bytes.fromhex(lines[0][1]) and read[1] in (0x1301, 0x1302, 0x1303) and read[2] == "localhost", read
found = tlsrecords.quic_session(datagrams, *read)
assert found and any(side == 0 and kind == tlsrecords.SHORT_PACKET for side, kind, _, _ in found.records), found
sessions.append(found)
logs.append(written)
CASES.append(("curl", "ngtcp2"))
print("curl's QUIC read from its Initial packets alone")

# Two short packets of the client in one batch, as GSO hands them over, have to come apart where the second begins.
short = [packet for side, kind, _, packet in found.records if side == 0 and kind == tlsrecords.SHORT_PACKET][:2]
if len(short) == 2:
    answer = next(datagram for side, datagram in datagrams if side == 1)
    identifier = len(next(source for kind, _, _, _, _, source in tlsrecords.quic_packets(answer, None) if kind == "initial"))
    parts = [packet for _, _, _, packet, _, _ in tlsrecords.quic_packets(short[0] + short[1], identifier)]
    assert parts == short, [len(p) for p in parts]



async def resumed(keys):
    """Two connections of one client: the first gets a ticket, and the second asks its question as early data with it."""
    tickets, kept = {}, []
    configuration = QuicConfiguration(alpn_protocols=["test"], is_client=False)
    configuration.load_cert_chain("cert.pem", "key.pem")
    port = free_port()
    listener = await serve("127.0.0.1", port, configuration=configuration,
                           stream_handler=lambda reader, writer: asyncio.ensure_future(handle(reader, writer)),
                           session_ticket_fetcher=lambda label: tickets.pop(label, None),
                           session_ticket_handler=lambda ticket: tickets.__setitem__(ticket.ticket, ticket))
    relay = Relay(port)
    first = QuicConfiguration(alpn_protocols=["test"], is_client=True, verify_mode=ssl.CERT_NONE)
    async with connect("127.0.0.1", relay.port, configuration=first, session_ticket_handler=kept.append) as client:
        reader, writer = await client.create_stream()
        writer.write(b"first")
        writer.write_eof()
        await reader.read()
    await asyncio.sleep(0.2)
    relay.kept.clear()
    second = QuicConfiguration(alpn_protocols=["test"], is_client=True, verify_mode=ssl.CERT_NONE, secrets_log_file=keys, session_ticket=kept[-1])
    async with connect("127.0.0.1", relay.port, configuration=second, wait_connected=False) as client:
        reader, writer = await client.create_stream()
        writer.write(b"early question")
        writer.write_eof()
        assert await reader.read() == b"answer to early question"
        await asyncio.sleep(0.2)
    listener.close()
    return relay.kept


with open("early.log", "w") as keys:
    datagrams = asyncio.run(resumed(keys))
with open("early.log") as f:
    lines = [line.split() for line in f if line.strip() and not line.startswith("#")]
early = {label: bytes.fromhex(secret) for label, _, secret in lines}
opened_by = bytes.fromhex(lines[0][1])
assert "CLIENT_EARLY_TRAFFIC_SECRET" in early, lines
assert any(side == 0 and kind == "early" for side, datagram in datagrams for kind, *_ in tlsrecords.quic_packets(datagram, None)), \
    "the client sent no early data, so this tests nothing"
# Only what the client sent, as when its early data goes out and the server has not answered yet.
sent = [d for d in datagrams if d[0] == 0]
assert tlsrecords.quic_client_hello(sent, scanner.quic_initial) == (opened_by, ""), "the client's hello was not read from its own packets"
found = tlsrecords.quic_session(datagrams, *tlsrecords.quic_hellos(datagrams, scanner.quic_initial))
assert any(side == 0 and kind == tlsrecords.EARLY_PACKET for side, kind, _, _ in found.records), found.records
hidden = bytearray(os.urandom(1 << 16))
hidden[4096: 4096 + 32] = early["CLIENT_EARLY_TRAFFIC_SECRET"]
hits = scanner.scan(hidden, len(hidden), 0x10000, [found], step=8, threads=1)
assert [(hit.label, hit.secret, hit.address) for hit in hits] == [("CLIENT_EARLY_TRAFFIC_SECRET", early["CLIENT_EARLY_TRAFFIC_SECRET"], 0x10000 + 4096)], hits
print("the secret of early data is found and named, the client's hello read before the server answers")

rng = random.Random(11)
memory = bytearray(os.urandom(1 << 20))
wanted = {}
LABELS = ["CLIENT_HANDSHAKE_TRAFFIC_SECRET", "SERVER_HANDSHAKE_TRAFFIC_SECRET", "CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0"]
for number, written in enumerate(logs):
    memory += (0x00007FF600000000 | rng.getrandbits(32)).to_bytes(8, "little") * 8
    for label in LABELS:
        wanted[(number, label)] = len(memory)
        memory += written[label] + bytes(8)
        memory += bytes([written[label][0] ^ 1]) + written[label][1:] + bytes(8)
    memory += bytes(-len(memory) % 8) + os.urandom(rng.randrange(1, 64) * 8)

base = 0x7FF612340000
hits = scanner.scan(memory, len(memory), base, sessions, step=8, threads=max(1, min(8, len(os.sched_getaffinity(0)))))
print(f"scan: {len(hits)} secrets, {scanner.tested} candidates")
for hit in hits:
    number = sessions.index(hit.session)
    assert logs[number].get(hit.label) == hit.secret, f"connection {number} {CASES[number]}: {hit.label} is not what aioquic wrote"
    assert wanted[(number, hit.label)] + base == hit.address, f"connection {number}: {hit.label} at {hit.address:#x}"
for number, found in enumerate(sessions):
    labels = {hit.label for hit in hits if hit.session is found}
    assert {"CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0"} <= labels, f"connection {number} {CASES[number]}: found only {labels}"

damaged = tlsrecords.Session()
damaged.__dict__.update(sessions[0].__dict__, records=[(s, k, at, packet[:-1] + bytes([packet[-1] ^ 1])) for s, k, at, packet in sessions[0].records])
assert scanner.scan(memory, len(memory), base, [damaged], step=8) == [], "a damaged packet was opened"
print("tlsscan finds QUIC's secrets and nothing else")

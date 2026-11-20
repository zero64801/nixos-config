"""keys scan's search on real TLS: OpenSSL's s_client talks to s_server through a relay that keeps what went each way, in
every suite the scanner knows, and the secrets of its own key log are hidden in made up memory among noise. The scanner
has to find each of them where it was put, label it as OpenSSL did, and find nothing else.

GnuTLS's client and server do the same for RC4 and 3DES, which OpenSSL no longer has.

usage: tlsscan_logic.py CAPTURE_CODE LIBTLSSCAN OPENSSL GNUTLS_FOLDER"""
import os
import random
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, sys.argv[1])
import scan
import tlsrecords

library, openssl, gnutls = sys.argv[2], sys.argv[3], sys.argv[4]
scanner = scan.Scanner(library)
threads = max(1, min(8, len(os.sched_getaffinity(0))))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def server(*options, command=None):
    port = free_port()
    command = command(port) if command else [openssl, "s_server", "-accept", f"127.0.0.1:{port}", "-cert", "cert.pem", "-key", "key.pem", "-www",
                                             "-cipher", "ALL:@SECLEVEL=0", *options]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return process, port
        time.sleep(0.05)
    sys.exit("s_server did not start")


class Relay:
    """Passes connections on to a server and keeps what each side sent, one pair for each connection."""

    def __init__(self, target):
        self.target, self.kept, self.done = target, [], []
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            client, _ = self.listener.accept()
            upstream = socket.create_connection(("127.0.0.1", self.target))
            pair, finished = [bytearray(), bytearray()], threading.Event()
            self.kept.append(pair)
            self.done.append(finished)
            ends = []

            def pump(source, sink, into, ends=ends, finished=finished):
                while chunk := source.recv(65536):
                    into += chunk
                    sink.sendall(chunk)
                try:
                    sink.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                ends.append(1)
                if len(ends) == 2:
                    finished.set()

            threading.Thread(target=pump, args=(client, upstream, pair[0]), daemon=True).start()
            threading.Thread(target=pump, args=(upstream, client, pair[1]), daemon=True).start()


def talk(relay, *options):
    """One connection of s_client through the relay, or of gnutls-cli with a priority string, the session the relay saw and
    the key log the client wrote."""
    if os.path.exists("keys.log"):
        os.unlink("keys.log")
    before = len(relay.kept)
    if options[0].startswith("NORMAL"):
        subprocess.run([f"{gnutls}/gnutls-cli", "--insecure", "-p", str(relay.port), "127.0.0.1", "--priority", options[0]],
                       input=b"hello\n", env=dict(os.environ, SSLKEYLOGFILE="keys.log"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=30, check=True)
    else:
        subprocess.run([openssl, "s_client", "-connect", f"127.0.0.1:{relay.port}", "-keylogfile", "keys.log", "-quiet", *options],
                       input=b"GET / HTTP/1.0\r\n\r\n", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=True)
    assert relay.done[before].wait(10), options
    client, server = relay.kept[before]
    found = tlsrecords.session(bytes(client), bytes(server))
    assert found, f"no TLS session in what {options} sent"
    with open("keys.log") as f:
        # With RSA key exchange OpenSSL also logs the premaster secret by the start of its encryption, which no scan looks for.
        lines = [line.split() for line in f if line.strip() and not line.startswith(("#", "RSA "))]
    assert lines and all(bytes.fromhex(line[1]) == found.client_random for line in lines), f"the key log is of another connection: {options}"
    return found, {line[0]: bytes.fromhex(line[2]) for line in lines}


subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "1",
                "-subj", "/CN=tls.test"], check=True, capture_output=True)
plain_server, plain_port = server("-ciphersuites", "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:"
                                                   "TLS_AES_128_CCM_SHA256:TLS_AES_128_CCM_8_SHA256")
retry_server, retry_port = server("-groups", "P-256")
old_server, old_port = server(command=lambda port: [f"{gnutls}/gnutls-serv", "-p", str(port), "--echo", "--x509certfile", "cert.pem",
                                                    "--x509keyfile", "key.pem", "--priority",
                                                    "NORMAL:+ARCFOUR-128:+3DES-CBC:+VERS-TLS1.0:+VERS-TLS1.1:+RSA"])
relay, retry_relay, old_relay = Relay(plain_port), Relay(retry_port), Relay(old_port)

CASES = [
    (relay, 0x0304, 0x1301, ["-tls1_3", "-ciphersuites", "TLS_AES_128_GCM_SHA256"]),
    (relay, 0x0304, 0x1302, ["-tls1_3", "-ciphersuites", "TLS_AES_256_GCM_SHA384"]),
    (relay, 0x0304, 0x1303, ["-tls1_3", "-ciphersuites", "TLS_CHACHA20_POLY1305_SHA256"]),
    (retry_relay, 0x0304, 0x1302, ["-tls1_3", "-ciphersuites", "TLS_AES_256_GCM_SHA384"]),
    (relay, 0x0304, 0x1304, ["-tls1_3", "-ciphersuites", "TLS_AES_128_CCM_SHA256"]),
    (relay, 0x0304, 0x1305, ["-tls1_3", "-ciphersuites", "TLS_AES_128_CCM_8_SHA256", "-cipher", "DEFAULT:@SECLEVEL=0"]),
    (relay, 0x0303, 0xC09C, ["-tls1_2", "-cipher", "AES128-CCM:@SECLEVEL=0"]),
    (relay, 0x0303, 0xC0A1, ["-tls1_2", "-cipher", "AES256-CCM8:@SECLEVEL=0"]),
    (old_relay, 0x0303, 0xC011, ["NORMAL:-CIPHER-ALL:+ARCFOUR-128:-VERS-ALL:+VERS-TLS1.2:-KX-ALL:+ECDHE-RSA"]),
    (old_relay, 0x0301, 0x0005, ["NORMAL:-CIPHER-ALL:+ARCFOUR-128:-VERS-ALL:+VERS-TLS1.0:-KX-ALL:+RSA"]),
    (old_relay, 0x0303, 0xC012, ["NORMAL:-CIPHER-ALL:+3DES-CBC:-VERS-ALL:+VERS-TLS1.2:-KX-ALL:+ECDHE-RSA"]),
    (old_relay, 0x0301, 0x000A, ["NORMAL:-CIPHER-ALL:+3DES-CBC:-VERS-ALL:+VERS-TLS1.0:-KX-ALL:+RSA:%NO_ETM"]),
    (relay, 0x0303, 0xC02F, ["-tls1_2", "-cipher", "ECDHE-RSA-AES128-GCM-SHA256"]),
    (relay, 0x0303, 0xC030, ["-tls1_2", "-cipher", "ECDHE-RSA-AES256-GCM-SHA384"]),
    (relay, 0x0303, 0xCCA8, ["-tls1_2", "-cipher", "ECDHE-RSA-CHACHA20-POLY1305"]),
    (relay, 0x0303, 0xC013, ["-tls1_2", "-cipher", "ECDHE-RSA-AES128-SHA"]),
    (relay, 0x0303, 0xC013, ["-tls1_2", "-cipher", "ECDHE-RSA-AES128-SHA", "-no_etm"]),
    (relay, 0x0303, 0xC028, ["-tls1_2", "-cipher", "ECDHE-RSA-AES256-SHA384", "-no_etm"]),
    (relay, 0x0303, 0x003C, ["-tls1_2", "-cipher", "AES128-SHA256:@SECLEVEL=0", "-no_etm"]),
    (relay, 0x0303, 0x0035, ["-tls1_2", "-cipher", "AES256-SHA:@SECLEVEL=0"]),
    (relay, 0x0302, 0xC013, ["-tls1_1", "-cipher", "ECDHE-RSA-AES128-SHA:@SECLEVEL=0"]),
    (relay, 0x0302, 0xC014, ["-tls1_1", "-cipher", "ECDHE-RSA-AES256-SHA:@SECLEVEL=0", "-no_etm"]),
    (relay, 0x0301, 0x002F, ["-tls1", "-cipher", "AES128-SHA:@SECLEVEL=0", "-no_etm"]),
    (relay, 0x0301, 0xC014, ["-tls1", "-cipher", "ECDHE-RSA-AES256-SHA:@SECLEVEL=0"]),
]
sessions, logs = [], []
for via, version, suite, options in CASES:
    found, log = talk(via, *options)
    assert (found.version, found.suite) == (version, suite), (options, found)
    assert scanner.supported(found), options
    if via is not old_relay:
        assert found.etm == ("-no_etm" not in options and version != 0x0304 and suite in (0xC013, 0xC014, 0x0035, 0x002F)), (options, found.etm)
    elif suite in (0xC012, 0x000A):
        assert found.etm == ("%NO_ETM" not in options[0]), (options, found.etm)
    sessions.append(found)
    logs.append(log)
plain_server.kill()
retry_server.kill()
old_server.kill()
print(f"{len(sessions)} sessions of OpenSSL and GnuTLS recorded")

# Memory as a process has it: pointers, small numbers, text, zeros and stretches of random bytes, which are what makes a
# search slow, with the secrets in made up structures among them.
rng = random.Random(7)
memory = bytearray()
for _ in range(64):
    kind = rng.randrange(4)
    size = rng.randrange(16, 160) * 1024
    if kind == 0:
        memory += b"".join((0x00007FF000000000 | rng.getrandbits(36)).to_bytes(8, "little") for _ in range(size // 8))
    elif kind == 1:
        memory += bytes(size)
    elif kind == 2:
        memory += (b"Content-Type: text/html; charset=utf-8\r\nServer: s_server\r\n" * (size // 57 + 1))[:size]
    else:
        memory += os.urandom(size)
    memory += bytes(-len(memory) % 8)

wanted = {}
for number, (found, log) in enumerate(zip(sessions, logs)):
    labels = ["CLIENT_RANDOM"] if found.version != 0x0304 else \
        ["CLIENT_HANDSHAKE_TRAFFIC_SECRET", "SERVER_HANDSHAKE_TRAFFIC_SECRET", "CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0"]
    structure = bytearray(found.client_random + os.urandom(32))
    for label in labels:
        structure += (0x00007FF600000000 | rng.getrandbits(32)).to_bytes(8, "little") * 3
        wanted[(number, label)] = len(memory) + len(structure)
        structure += log[label]
        # A copy with one bit changed, which opens nothing and must not be taken for the secret.
        structure += bytes(8) + bytes([log[label][0] ^ 1]) + log[label][1:]
    structure += bytes(-len(structure) % 8)
    memory += structure
    memory += os.urandom(rng.randrange(1, 64) * 8)
print(f"{len(memory) // (1 << 20)} MiB of made up memory")

base = 0x7FF612340000
started = time.monotonic()
hits = scanner.scan(memory, len(memory), base, sessions, step=8, threads=threads)
took = time.monotonic() - started
print(f"scan: {len(hits)} secrets, {scanner.tested} candidates tried in {took:.1f} s with {threads} threads")
for hit in hits:
    number = sessions.index(hit.session)
    assert logs[number].get(hit.label) == hit.secret, f"session {number}: {hit.label} is not what OpenSSL wrote"
    assert wanted[(number, hit.label)] + base == hit.address, f"session {number}: {hit.label} at {hit.address:#x}"
for number, found in enumerate(sessions):
    labels = {hit.label for hit in hits if hit.session is found}
    needed = {"CLIENT_RANDOM"} if found.version != 0x0304 else {"CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0"}
    assert needed <= labels, f"session {number} {CASES[number][3]}: found only {labels}"

anchors = scanner.find(memory, len(memory), base, [found.client_random for found in sessions], threads=threads)
for number, found in enumerate(sessions):
    assert any(which == number for _, which in anchors), f"the client random of session {number} was not found"
    assert all(memory[a - base: a - base + 32] == sessions[w].client_random for a, w in anchors)
print(f"find: {len(anchors)} places of {len(sessions)} client randoms")

# A secret at no multiple of eight is out of a scan at step 8, and in one at step 1 around its anchor.
odd = bytearray(os.urandom(4096) + sessions[0].client_random + bytes(3) + logs[0]["CLIENT_TRAFFIC_SECRET_0"] + bytes(6)
                + logs[0]["SERVER_TRAFFIC_SECRET_0"] + os.urandom(4096))
assert not [h for h in scanner.scan(odd, len(odd), 0, sessions[:1], step=8) if h.label.endswith("TRAFFIC_SECRET_0")], "found off its step"
near = scanner.scan(odd, len(odd), 0, sessions[:1], step=1)
assert {h.label for h in near} >= {"CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0"}, [h.label for h in near]

assert scanner.scan(os.urandom(1 << 20), 1 << 20, 0, sessions, step=8, threads=threads) == [], "random memory gave a secret"
broken = tlsrecords.Session()
broken.__dict__.update(sessions[0].__dict__, records=[(d, k, v, body[:-1] + bytes([body[-1] ^ 1])) for d, k, v, body in sessions[0].records])
assert scanner.scan(memory, len(memory), base, [broken], step=8, threads=threads) == [], "a damaged record was opened"
print("tlsscan finds OpenSSL's secrets and nothing else")

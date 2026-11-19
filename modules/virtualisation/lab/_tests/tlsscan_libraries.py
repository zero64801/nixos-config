"""keys scan's search in the live memory of clients of different TLS libraries and languages: each connects through a
relay that keeps what went each way to a server that takes its request and holds the answer back, writes its own key log,
and while it waits its memory is read through /proc and searched the way keys scan searches a program of a guest.

usage: tlsscan_libraries.py CAPTURE_CODE LIBTLSSCAN CLIENTS_JSON EXPECTED_JSON
CLIENTS_JSON names each client's command, the environment it takes and whether the request comes on its standard input.
EXPECTED_JSON says, for each client, which secrets of its own key log the search has to find."""
import json
import os
import socket
import ssl
import subprocess
import sys
import threading
import time

sys.path.insert(0, sys.argv[1])
import scan
import tlsrecords

scanner = scan.Scanner(sys.argv[2])
with open(sys.argv[3]) as f:
    CLIENTS = json.load(f)
with open(sys.argv[4]) as f:
    EXPECTED = json.load(f)
TRAFFIC = ("CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0", "CLIENT_RANDOM")


class Hold:
    """A server of TLS 1.2 and 1.3 that takes a request, says so, and answers only when let go."""

    def __init__(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain("cert.pem", "key.pem")
        context.set_ciphers("ALL:@SECLEVEL=0")
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context, self.arrived, self.go = context, threading.Event(), threading.Event()
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            connection, _ = self.listener.accept()
            threading.Thread(target=self.answer, args=(connection,), daemon=True).start()

    def answer(self, connection):
        try:
            with self.context.wrap_socket(connection, server_side=True) as tls:
                data = b""
                while b"\r\n\r\n" not in data and b"\n\n" not in data:
                    more = tls.recv(4096)
                    if not more:
                        break
                    data += more
                self.arrived.set()
                self.go.wait(60)
                tls.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nok\n")
        except (OSError, ssl.SSLError):
            self.arrived.set()


class Relay:
    """Passes one connection at a time on to the server and keeps what each side sent."""

    def __init__(self, target):
        self.target, self.pair = target, None
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            client, _ = self.listener.accept()
            upstream = socket.create_connection(("127.0.0.1", self.target))
            self.pair = pair = [bytearray(), bytearray()]

            def pump(source, sink, into):
                try:
                    while chunk := source.recv(65536):
                        into += chunk
                        sink.sendall(chunk)
                except OSError:
                    pass
                for end in (sink, source):
                    try:
                        end.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass

            threading.Thread(target=pump, args=(client, upstream, pair[0]), daemon=True).start()
            threading.Thread(target=pump, args=(upstream, client, pair[1]), daemon=True).start()


class Memory:
    """The writable memory of a live process of this machine, read through /proc, as a source for keys scan's search."""

    def __init__(self, name, pid):
        self.name, self.pid = name, pid

    def __str__(self):
        return f"{self.name}[{self.pid}]"

    def regions(self, budget):
        found = []
        with open(f"/proc/{self.pid}/maps") as maps:
            spans = [line.split() for line in maps]
        descriptor = os.open(f"/proc/{self.pid}/mem", os.O_RDONLY)
        try:
            for span in spans:
                start, end = (int(x, 16) for x in span[0].split("-"))
                if "w" not in span[1] or (len(span) > 5 and span[5] in ("[vvar]", "[vsyscall]", "[vvar_vclock]")):
                    continue
                try:
                    data = bytearray(os.pread(descriptor, min(end - start, budget), start))
                except OSError:
                    continue
                budget -= len(data)
                found.append((start, data, len(data)))
        finally:
            os.close(descriptor)
        return found


class Args:
    around, max_memory, step, deep = 65536, 4096, None, True


def keylog(path):
    lines = {}
    try:
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 3 and not parts[0].startswith("#"):
                    lines[parts[0]] = bytes.fromhex(parts[2])
    except OSError:
        pass
    return lines


hold = Hold()
relay = Relay(hold.port)
results, failures = {}, []
for name, client in CLIENTS.items():
    hold.arrived.clear()
    hold.go.clear()
    log = os.path.abspath(f"{name}.keys")
    environment = dict(os.environ, **{key: value.replace("@LOG@", log) for key, value in client.get("env", {}).items()})
    command = [part.replace("@PORT@", str(relay.port)).replace("@LOG@", log) for part in client["command"]]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment)
    if client.get("stdin"):
        process.stdin.write(b"GET / HTTP/1.0\r\n\r\n")
        process.stdin.flush()
    if not hold.arrived.wait(20) or process.poll() is not None:
        process.kill()
        hold.go.set()
        failures.append(f"{name}: it did not connect: {process.stdout.read().decode(errors='replace')[-600:]}")
        continue
    time.sleep(0.5)
    started = time.monotonic()
    source = Memory(name, process.pid)
    found = tlsrecords.session(bytes(relay.pair[0]), bytes(relay.pair[1]))
    written = keylog(log)
    hits = []
    if found:
        found.found = {}
        hits = scan.search(scanner, source, [found], Args)
    hold.go.set()
    try:
        process.stdin.close()
        process.wait(10)
    except (OSError, subprocess.TimeoutExpired):
        process.kill()
    labels = {hit.label for hit in hits}
    # What opens the flow's records is right by itself, and where the client wrote a key log it has to be what it wrote.
    right = {hit.label for hit in hits if not written or written.get(hit.label) == hit.secret}
    wrong = labels - right
    version = {0x0303: "1.2", 0x0304: "1.3"}.get(getattr(found, "version", 0), "?")
    results[name] = sorted(right)
    print(f"{name:<14} TLS {version} suite {getattr(found, 'suite', 0):#06x}: wrote {sorted(written) or 'no key log'}, found {sorted(right)}"
          f"{', WRONG ' + str(sorted(wrong)) if wrong else ''}, {time.monotonic() - started:.1f} s", flush=True)
    if wrong:
        failures.append(f"{name}: a secret was taken that the client did not write: {sorted(wrong)}")
    for label in EXPECTED.get(name, []):
        if label not in right:
            failures.append(f"{name}: {label} was not found")
assert not failures, "\n".join(failures)
print("every library's secrets were found where expected")

"""The gateway against a stand-in symbol server, asked directly and through the patched library.

usage: symbol-gateway-test.py GATEWAY LIBPDBCRUST
"""
import ctypes
import http.server
import os
import socket
import subprocess
import sys
import threading
import time

gateway, library = sys.argv[1], sys.argv[2]
NAME, IDENTIFIER = "ntkrnlmp.pdb", "0C3FB08B9223E2EFB08FA14331050B261"
CONTENT = os.urandom(0x3000)
asked = []


class SymbolServer(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        asked.append(self.path)
        found = self.path == f"/{NAME}/{IDENTIFIER}/{NAME}"
        body = CONTENT if found else b"no such file"
        self.send_response(200 if found else 404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def ask(line):
    with socket.socket(socket.AF_UNIX) as client:
        client.connect("gateway.sock")
        client.sendall(line)
        answer = client.makefile("rb")
        return answer.read(int(answer.readline()))


upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SymbolServer)
threading.Thread(target=upstream.serve_forever, daemon=True).start()
running = subprocess.Popen([gateway, "gateway.sock", "cache", f"http://127.0.0.1:{upstream.server_port}"])
try:
    for _ in range(100):
        if os.path.exists("gateway.sock"):
            break
        time.sleep(0.1)

    request = f"{NAME} {IDENTIFIER}\n".encode()
    assert ask(request) == CONTENT, "the file the server has"
    assert ask(request.lower()) == CONTENT, "the identifier in lower case"
    assert len(asked) == 1, asked

    refused = [
        b"../../etc/passwd " + IDENTIFIER.encode() + b"\n",
        b"sub/ntkrnlmp.pdb " + IDENTIFIER.encode() + b"\n",
        b".pdb " + IDENTIFIER.encode() + b"\n",
        b"ntkrnlmp.exe " + IDENTIFIER.encode() + b"\n",
        b"ntkrnlmp.pdb ../../../../etc\n",
        b"ntkrnlmp.pdb " + IDENTIFIER.encode() + b" more\n",
        b"ntkrnlmp.pdb 0C3F\n",
        b"GET / HTTP/1.1\n",
        b"x" * 500 + b"\n",
        b"\n",
    ]
    for line in refused:
        assert ask(line) == b"", line
    assert len(asked) == 1, f"a refused request reached the server: {asked}"

    assert ask(f"other.pdb {IDENTIFIER}\n".encode()) == b"", "a file the server does not have"
    assert not os.path.exists(f"cache/other.pdb/{IDENTIFIER}/other.pdb")

    upstream.shutdown()
    upstream.server_close()
    assert ask(request) == CONTENT, "kept once fetched"

    ensure = ctypes.CDLL(library).pdbcrust_pdb_download_ensure
    ensure.restype = ctypes.c_bool
    ensure.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_bool, ctypes.c_size_t, ctypes.c_char_p]
    os.environ["PDBCRUST_SYMBOL_SOCKET"] = os.path.abspath("gateway.sock")
    os.mkdir("local")
    path = ctypes.create_string_buffer(1024)
    assert ensure(b"local", IDENTIFIER.encode(), NAME.encode(), True, len(path), path), "the library through the socket"
    with open(path.value, "rb") as file:
        assert file.read() == CONTENT
    assert not ensure(b"local", IDENTIFIER.encode(), b"other.pdb", True, len(path), path), "the library, for a missing file"

    # Several MemProcFS started together in one lab share an empty cache, and each has to get every file whole.
    for attempt in range(20):
        folder = f"race{attempt}".encode()
        os.mkdir(folder)
        start, results = threading.Barrier(8), []

        def fetch(start=start, folder=folder, results=results):
            found = ctypes.create_string_buffer(1024)
            start.wait()
            if ensure(folder, IDENTIFIER.encode(), NAME.encode(), True, len(found), found):
                with open(found.value, "rb") as file:
                    results.append(file.read() == CONTENT)
            else:
                results.append(False)

        fetching = [threading.Thread(target=fetch) for _ in range(8)]
        for thread in fetching:
            thread.start()
        for thread in fetching:
            thread.join()
        assert results == [True] * 8, f"attempt {attempt}: {results.count(True)} of 8 got the whole file"
        assert os.listdir(f"race{attempt}/{NAME}/{IDENTIFIER}") == [NAME], os.listdir(f"race{attempt}/{NAME}/{IDENTIFIER}")
finally:
    running.kill()

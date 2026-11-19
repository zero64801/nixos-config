"""How guest-net undoes the encodings of HTTP bodies and shows them: each encoding servers use, a chain of them, a body
that is not what its header says, one made to grow without end, and JSON laid out. Started with the folder of
guest-net's code."""
import gzip
import json
import sys
import zlib

import brotli
from compression import zstd

sys.path.insert(0, sys.argv[1])
import bodies

plain = json.dumps({"user": "alice", "items": [1, 2, 3], "note": "körper"}).encode()
raw = zlib.compressobj(wbits=-zlib.MAX_WBITS)
for name, data in (("gzip", gzip.compress(plain)), ("x-gzip", gzip.compress(plain)), ("deflate", zlib.compress(plain)),
                   ("deflate", raw.compress(plain) + raw.flush()), ("br", brotli.compress(plain)), ("zstd", zstd.compress(plain)),
                   ("identity", plain), ("", plain), ("gzip, br", brotli.compress(gzip.compress(plain))), ("GZIP", gzip.compress(plain))):
    out, note = bodies.decoded(data, name)
    assert (out, note) == (plain, ""), (name, out[:40], note)

out, note = bodies.decoded(b"not gzip at all", "gzip")
assert out == b"not gzip at all" and note.startswith("not undone of gzip"), note
out, note = bodies.decoded(plain, "compress")
assert out == plain and "compress is no encoding" in note, note

huge = b"\0" * ((bodies.LIMIT >> 20) + 16 << 20)
for name, data in (("gzip", gzip.compress(huge, 1)), ("br", brotli.compress(huge, quality=1)), ("zstd", zstd.compress(huge))):
    out, note = bodies.decoded(data, name)
    assert len(out) == bodies.LIMIT and note == f"cut at {bodies.LIMIT >> 20} MiB", (name, len(out), note)

shown = bodies.text(plain, "application/json; charset=utf-8", 4000)
assert shown.splitlines()[:2] == ["{", '  "user": "alice",'] and "körper" in shown, shown
assert bodies.text(b'[1, 2]', "", 4000) == "[\n  1,\n  2\n]"
assert bodies.text(b"{not json", "application/json", 4000) == "{not json"
assert bodies.text(bytes(range(256)) * 8, "application/octet-stream", 4000) is None
assert bodies.text(b"x" * 50, "text/plain", 10) == "x" * 10 + "\n... (50 characters)"
assert bodies.text(b"<p>a</p>\r\n<p>b</p>\r\n", "text/html", 4000) == "<p>a</p>\n<p>b</p>\n"
print("bodies are undone and shown as meant")

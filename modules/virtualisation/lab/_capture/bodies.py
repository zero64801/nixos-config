"""The bodies of HTTP requests and answers as they are meant: undone of the encodings their headers name, and shown as text
or as JSON laid out. tshark undoes what it knows already, so this is for what it left as it came. The bodies are the
guest's or a server's, so nothing is decoded beyond a limit, and a body that claims an encoding it does not have is
shown as it came."""
import json
import zlib

try:
    import brotli
except ImportError:
    brotli = None
try:
    from compression import zstd
except ImportError:
    zstd = None

LIMIT = 64 << 20
SHOWN = 4096


class Unreadable(ValueError):
    """A body that is not in the encoding its header names."""


def inflate(data, wbits):
    worker = zlib.decompressobj(wbits)
    try:
        out = worker.decompress(data, LIMIT)
    except zlib.error as e:
        raise Unreadable(str(e)) from e
    return out, bool(worker.unconsumed_tail)


def unbrotli(data):
    if brotli is None:
        raise Unreadable("this lab has no brotli")
    worker, out = brotli.Decompressor(), bytearray()
    # Fed in small pieces, so that a body made to grow past any size stops at the limit.
    for at in range(0, len(data), 1024):
        try:
            out += worker.process(data[at: at + 1024])
        except brotli.error as e:
            raise Unreadable(str(e)) from e
        if len(out) > LIMIT:
            return bytes(out[:LIMIT]), True
    return bytes(out), False


def unzstd(data):
    if zstd is None:
        raise Unreadable("this lab's Python has no zstd")
    try:
        out = zstd.ZstdDecompressor().decompress(data, max_length=LIMIT)
    except zstd.ZstdError as e:
        raise Unreadable(str(e)) from e
    return out, len(out) >= LIMIT


def undo(name, data):
    """One encoding undone: (the data, whether it was cut at the limit)."""
    if name in ("gzip", "x-gzip"):
        return inflate(data, 16 + zlib.MAX_WBITS)
    if name == "deflate":
        # What servers send as deflate is meant to be zlib's format and is raw deflate often enough.
        try:
            return inflate(data, zlib.MAX_WBITS)
        except Unreadable:
            return inflate(data, -zlib.MAX_WBITS)
    if name == "br":
        return unbrotli(data)
    if name == "zstd":
        return unzstd(data)
    if name in ("", "identity"):
        return data, False
    raise Unreadable(f"{name} is no encoding this knows")


def decoded(data, encoding):
    """The body undone of its content-encoding, which lists the encodings in the order they were applied, and a note
    when it could not be or was cut."""
    cut = False
    for name in reversed([part.strip().lower() for part in (encoding or "").split(",") if part.strip()]):
        try:
            data, shortened = undo(name, data)
        except Unreadable as e:
            return data, f"not undone of {name}: {e}"
        cut = cut or shortened
    return data, f"cut at {LIMIT >> 20} MiB" if cut else ""


def text(data, kind, limit):
    """The body as it reads: JSON laid out, text as it is, and None for what is not text."""
    sample = data[:SHOWN]
    if not sample or sum(32 <= b < 127 or b in (9, 10, 13) or b >= 0x80 for b in sample) < 0.95 * len(sample):
        return None
    words = data.decode("utf-8", "replace").replace("\r\n", "\n")
    if "json" in (kind or "").lower() or words.lstrip()[:1] in ("{", "["):
        try:
            words = json.dumps(json.loads(words), indent=2, ensure_ascii=False)
        except ValueError:
            pass
    return words[:limit] + (f"\n... ({len(words)} characters)" if len(words) > limit else "")

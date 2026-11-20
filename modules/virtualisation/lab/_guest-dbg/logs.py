"""guest-dbg --log: at each stop at a place, a buffer of the process written to ./out and a line about it printed, and the
guest let go. What the buffer and its length are is said per place, in registers and memory, at the function's entry or
at its return, and presets say it for the functions where a program's data is plain: before it is encrypted, sent or
after it is received or decrypted. Only the guest's memory is read, nothing in it is changed.

A value is a register (rcx, r8, ...), argN in Windows' x64 calling convention (the first four in rcx, rdx, r8 and r9,
the rest on the stack at the entry), ret for what the function returned, or a number, with * in front to read memory
there, :4 or :8 for its size, and @return to take it when the function returns. A buffer can also be wsabuf:BUFFERS:COUNT,
the WSABUF array of Winsock, secbuffers:DESCRIPTOR, the data buffers of an SSPI SecBufferDesc, clrstring:VALUE, a string
of .NET, written as UTF-8, or clrbytes:VALUE, a byte array of .NET. A method of .NET takes its arguments as Windows' x64
convention has them, an instance method its object as arg1.
"""
import json
import os
import re
import time

# Windows x64: the first four arguments in registers, the rest on the stack above the return address and the home space.
ARGUMENTS = ["rcx", "rdx", "r8", "r9"]
PRESETS = {
    "send": ["ws2_32!send,arg2,arg3:4"],
    "recv": ["ws2_32!recv,arg2,ret:4@return"],
    "wsasend": ["ws2_32!WSASend,wsabuf:arg2:arg3,-"],
    "wsarecv": ["ws2_32!WSARecv,wsabuf:arg2:arg3,*arg4:4@return"],
    "winsock": ["ws2_32!send,arg2,arg3:4", "ws2_32!recv,arg2,ret:4@return"],
    "bcrypt": ["bcrypt!BCryptEncrypt,arg2,arg3:4", "bcrypt!BCryptDecrypt,arg7,*arg9:4@return", "bcrypt!BCryptGenerateSymmetricKey,arg5,arg6:4"],
    "sspi": ["sspicli!EncryptMessage,secbuffers:arg3,-", "sspicli!DecryptMessage,secbuffers:arg2,-@return"],
    "winhttp": ["winhttp!WinHttpWriteData,arg2,arg3:4", "winhttp!WinHttpReadData,arg2,*arg4:4@return"],
    "openssl": ["MODULE!SSL_write,arg2,arg3:4", "MODULE!SSL_read,arg2,ret:4@return"],
}
VALUE = re.compile(r"(\*)?(r[a-z0-9]+|e[a-z]{2}|arg\d+|ret|0x[0-9a-fA-F]+|\d+)(?::(4|8))?")
DATA = 1
# Buffers that say their own length: Winsock's, SSPI's, and .NET's objects.
SIZED = ("wsabuf:", "secbuffers:", "clrstring:", "clrbytes:")
# A .NET object on x64 begins with its type's pointer. A string's length in characters follows, then its UTF-16, and an
# array's length is padded to eight bytes before its elements.
STRING_LENGTH, STRING_CHARACTERS, ARRAY_LENGTH, ARRAY_ELEMENTS = 8, 12, 8, 16


class Spec:
    """One place to log at: where, the buffer, its length, and whether any of it waits for the return."""

    def __init__(self, text):
        parts = text.split(",")
        if len(parts) != 3:
            raise ValueError(f"{text}: a log is PLACE,BUFFER,LENGTH")
        self.place, self.buffer, self.length = (part.strip() for part in parts)
        managed = self.buffer.removesuffix("@return").split(":", 1)[1] if self.buffer.startswith(("clrstring:", "clrbytes:")) else None
        self.at_return = self.buffer.endswith("@return") or self.length.endswith("@return") or "ret" in (self.buffer, self.length.split(":")[0], managed)
        self.buffer, self.length = self.buffer.removesuffix("@return"), self.length.removesuffix("@return")
        self.label = self.place.split("!")[-1]
        for part in (self.buffer, self.length):
            if part != "-" and not part.startswith(SIZED) and not VALUE.fullmatch(part):
                raise ValueError(f"{text}: {part} is not a value this reads")
        if managed is not None and not VALUE.fullmatch(managed):
            raise ValueError(f"{text}: {managed} is not a value this reads")
        if self.length == "-" and not self.buffer.startswith(SIZED):
            raise ValueError(f"{text}: only wsabuf, secbuffers, clrstring and clrbytes know their own length")


def expand(words):
    """The specs of --log options, presets by name, openssl=MODULE with its module."""
    specs = []
    for word in words:
        name, _, module = word.partition("=")
        if name in PRESETS:
            if name == "openssl" and not module:
                raise ValueError("openssl takes the module that has OpenSSL, as openssl=libssl-3-x64.dll")
            specs += [Spec(spec.replace("MODULE", module)) for spec in PRESETS[name]]
        else:
            specs.append(Spec(word))
    return specs


class Reader:
    """Values and buffers of a stopped process, from its registers at the entry and now, through gdb."""

    def __init__(self, debugger, entry, now):
        self.debugger, self.entry, self.now = debugger, entry, now

    def value(self, text):
        matched = VALUE.fullmatch(text)
        star, base, size = matched.groups()
        if base == "ret":
            value = self.now["rax"]
        elif base.startswith("arg"):
            number = int(base[3:])
            value = self.entry[ARGUMENTS[number - 1]] if number <= 4 else self.debugger.word(self.entry["rsp"] + 8 * number)
        elif base.startswith(("r", "e")):
            # A register at the entry, since the function has changed most of them by its return, and ret is what it gave back.
            value = self.entry.get("r" + base[1:] if base.startswith("e") else base)
            size = size or ("4" if base.startswith("e") else None)
        else:
            value = int(base, 0)
        if value is None:
            raise LookupError(f"{text} has no value here")
        if star:
            value = int.from_bytes(self.debugger.read(value, int(size or 8)), "little")
        elif size:
            value &= (1 << (8 * int(size))) - 1
        return value

    def buffer(self, spec, limit):
        """The bytes the spec names, cut at the limit, and a note when they were cut."""
        kind = spec.buffer.split(":")[0]
        if kind == "wsabuf":
            _, where, count = spec.buffer.split(":")
            array, count = self.value(where), min(self.value(count), 64)
            pieces = []
            for n in range(count):
                entry = self.debugger.read(array + 16 * n, 16)
                pieces.append((int.from_bytes(entry[8:16], "little"), int.from_bytes(entry[0:4], "little")))
        elif kind == "secbuffers":
            descriptor = self.value(spec.buffer.split(":", 1)[1])
            head = self.debugger.read(descriptor, 16)
            count, array = min(int.from_bytes(head[4:8], "little"), 16), int.from_bytes(head[8:16], "little")
            pieces = []
            for n in range(count):
                entry = self.debugger.read(array + 16 * n, 16)
                if int.from_bytes(entry[4:8], "little") & 0x0FFFFFFF == DATA:
                    pieces.append((int.from_bytes(entry[8:16], "little"), int.from_bytes(entry[0:4], "little")))
        elif kind in ("clrstring", "clrbytes"):
            address = self.value(spec.buffer.split(":", 1)[1])
            if not address:
                return b"", "null"
            if kind == "clrstring":
                count = int.from_bytes(self.debugger.read(address + STRING_LENGTH, 4), "little")
                pieces = [(address + STRING_CHARACTERS, 2 * count)]
            else:
                pieces = [(address + ARRAY_ELEMENTS, int.from_bytes(self.debugger.read(address + ARRAY_LENGTH, 4), "little"))]
        else:
            pieces = [(self.value(spec.buffer), self.value(spec.length))]
        if spec.length != "-" and kind == "wsabuf":
            # What WSARecv received fills its buffers in order, up to the count it returned.
            left, cut = self.value(spec.length), []
            for address, size in pieces:
                cut.append((address, min(size, left)))
                left -= cut[-1][1]
            pieces = cut
        data, note = bytearray(), ""
        for address, size in pieces:
            if size > 0x7FFFFFFF:
                note = "a length that is an error code"
                continue
            if len(data) + size > limit:
                size, note = max(0, limit - len(data)), f"cut at {limit} bytes"
            if size:
                data += self.debugger.read(address, size)
        if kind == "clrstring":
            return bytes(data[: len(data) & ~1]).decode("utf-16-le", "replace").encode("utf-8"), note
        return bytes(data), note


class Writer:
    """The buffers, each a file in ./out/NAME, with an index of them as JSON lines."""

    def __init__(self, name):
        out = os.path.realpath("out")
        if not os.path.isdir(out):
            raise LookupError("there is no ./out folder to write the buffers to")
        self.folder = os.path.join(out, os.path.basename(name))
        os.mkdir(self.folder, 0o700)
        self.count, self.started = 0, time.time()

    def write(self, label, thread, where, data, note):
        """The buffer as the next file, and a line of the index, thread being the guest's CPU that stopped, as QEMU's stub names it."""
        self.count += 1
        name = f"{self.count:05d}-{re.sub(r'[^A-Za-z0-9_.-]', '_', label)}.bin"
        with open(os.open(os.path.join(self.folder, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
            f.write(data)
        with open(os.open(os.path.join(self.folder, "index.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "a") as f:
            f.write(json.dumps({"n": self.count, "time": time.time(), "label": label, "cpu": thread, "at": where, "length": len(data),
                                "file": name, **({"note": note} if note else {})}) + "\n")
        return name


def preview(data, width=96):
    """The start of a buffer as text when it reads as text, as hex otherwise."""
    sample = data[:width]
    if sample and sum(32 <= b < 127 or b in (9, 10, 13) for b in sample) >= 0.9 * len(sample):
        return "".join(chr(b) if 32 <= b < 127 else "." for b in sample)
    return sample[:32].hex(" ")

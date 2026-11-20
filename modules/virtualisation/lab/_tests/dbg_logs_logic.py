"""guest-dbg --log on made up registers and memory: the presets' buffers in Windows' x64 calling convention, from registers
and from the stack, at the entry and at the return, Winsock's WSABUF arrays and SSPI's SecBuffers, .NET's strings and byte
arrays, lengths that are error codes, buffers cut at the limit, and the files written for them. Started with the folder of
guest-dbg's code."""
import json
import os
import struct
import sys
import tempfile

sys.path.insert(0, sys.argv[1])
import logs


class Memory:
    """A process's memory as a few places with bytes, as the debugger reads it at a stop."""

    def __init__(self, places):
        self.places = places

    def read(self, address, length):
        for start, data in self.places.items():
            if start <= address and address + length <= start + len(data):
                return data[address - start: address - start + length]
        raise LookupError(f"{address:#x} is not mapped")

    def word(self, address):
        return int.from_bytes(self.read(address, 8), "little")


def spec(name, index=0, module=""):
    return logs.expand([f"{name}={module}" if module else name])[index]


def qwords(*values):
    return b"".join(struct.pack("<Q", v) for v in values)


stack = 0x8000
memory = Memory({
    0x1000: b"hello",
    0x2000: b"K" * 16,
    0x2800: b"decrypted text",
    0x2900: struct.pack("<I", 9),
    0x3000: struct.pack("<II", 3, 0) + qwords(0x4000) + struct.pack("<II", 4, 0) + qwords(0x5000),
    0x3800: struct.pack("<I", 5),
    0x4000: b"abc",
    0x5000: b"defg",
    0x6000: struct.pack("<II", 0, 3) + qwords(0x6100),
    0x6100: struct.pack("<II", 5, 7) + qwords(0x6200) + struct.pack("<II", 6, 0x80000001) + qwords(0x7000) + struct.pack("<II", 16, 6) + qwords(0x6300),
    0x7000: b"secret",
    # At a function's entry the stack holds the return address, the home space of four arguments, then the fifth and on.
    stack: qwords(0x7FF600001234, 0, 0, 0, 0, 0x2000, 16, 0x2800, 64, 0x2900),
    # A string of .NET: its type, its length in characters, its UTF-16. A byte array: its type, its length padded to eight, its bytes.
    0x9000: qwords(0x7FF8EA0A0000) + struct.pack("<I", 6) + "héllo!".encode("utf-16-le"),
    0x9100: qwords(0x7FF8EA0B0000) + struct.pack("<II", 3, 0) + bytes([1, 2, 3]),
})
entry = {"rcx": 0x10, "rdx": 0x1000, "r8": 5, "r9": 0x3800, "rsp": stack, "rax": 0, "rsi": 0x1000, "rdi": 0}

send = spec("send")
assert (send.place, send.at_return) == ("ws2_32!send", False)
assert logs.Reader(memory, entry, entry).buffer(send, 1 << 20) == (b"hello", "")

key = spec("bcrypt", 2)
assert key.label == "BCryptGenerateSymmetricKey" and logs.Reader(memory, entry, entry).buffer(key, 1 << 20) == (b"K" * 16, ""), "args 5 and 6 come from the stack"

decrypt = spec("bcrypt", 1)
assert decrypt.at_return and logs.Reader(memory, entry, dict(entry, rax=0)).buffer(decrypt, 1 << 20) == (b"decrypted", ""), \
    "BCryptDecrypt's plaintext is arg 7, as long as the count arg 9 points to says at the return"

recv = spec("recv")
assert recv.at_return
assert logs.Reader(memory, entry, dict(entry, rax=3)).buffer(recv, 1 << 20) == (b"hel", "")
assert logs.Reader(memory, entry, dict(entry, rax=0xFFFFFFFF)).buffer(recv, 1 << 20) == (b"", "a length that is an error code"), "recv's -1 read nothing"

wsa = dict(entry, rdx=0x3000, r8=2)
assert logs.Reader(memory, wsa, wsa).buffer(spec("wsasend"), 1 << 20) == (b"abcdefg", "")
assert logs.Reader(memory, wsa, wsa).buffer(spec("wsarecv"), 1 << 20) == (b"abcde", ""), "WSARecv fills its buffers up to what it received"

sspi = dict(entry, r8=0x6000, rdx=0x6000)
assert logs.Reader(memory, sspi, sspi).buffer(spec("sspi", 0), 1 << 20) == (b"secret", ""), "only the data buffer, its read only flag aside"
assert spec("sspi", 1).at_return and logs.Reader(memory, sspi, sspi).buffer(spec("sspi", 1), 1 << 20) == (b"secret", "")

assert logs.Reader(memory, entry, entry).buffer(send, 3) == (b"hel", "cut at 3 bytes")
ssl = spec("openssl", 1, "libssl-3-x64.dll")
assert ssl.place == "libssl-3-x64.dll!SSL_read" and ssl.at_return

linux = logs.Spec("0xffffffff81234560,rsi,ret@return")
assert linux.at_return and logs.Reader(memory, entry, dict(entry, rsi=0, rax=4)).buffer(linux, 1 << 20) == (b"hell", ""), \
    "a register at the return is the one the entry had"

for wrong, why in (("ws2_32!send,rdx", "PLACE,BUFFER,LENGTH"), ("ws2_32!send,rdx,-", "know their own length"), ("x,rdx,$(reboot)", "not a value"),
                   ("x,clrstring:$(reboot),-", "not a value")):
    try:
        logs.Spec(wrong)
        raise AssertionError(f"{wrong} was taken")
    except ValueError as e:
        assert why in str(e), e
for wrong in ("openssl", "nothing,at,all,here"):
    try:
        logs.expand([wrong])
        raise AssertionError(f"{wrong} was taken")
    except ValueError:
        pass

managed = dict(entry, rcx=0x9000, rdx=0x9100, r8=0)
assert logs.Reader(memory, managed, managed).buffer(logs.Spec("dotnet:Lab.Probe::Run,clrstring:arg1,-"), 1 << 20) == ("héllo!".encode(), ""), \
    "a .NET string comes as UTF-8"
assert logs.Reader(memory, managed, managed).buffer(logs.Spec("dotnet:Lab.Probe::Run,clrbytes:arg2,-"), 1 << 20) == (bytes([1, 2, 3]), "")
assert logs.Reader(memory, managed, managed).buffer(logs.Spec("dotnet:Lab.Probe::Run,clrbytes:arg3,-"), 1 << 20) == (b"", "null")
returned = logs.Spec("dotnet:Lab.Probe::Run,clrstring:ret,-")
assert returned.at_return and logs.Reader(memory, entry, dict(entry, rax=0x9000)).buffer(returned, 4) == (b"h\xc3\xa9", "cut at 4 bytes"), \
    "a returned string is taken at the return, and cut by its UTF-16 bytes"
assert logs.preview(b"GET / HTTP/1.1\r\n") == "GET / HTTP/1.1.." and logs.preview(bytes(range(4))) == "00 01 02 03"

os.chdir(tempfile.mkdtemp())
try:
    logs.Writer("none")
    raise AssertionError("a writer was made without ./out")
except LookupError:
    pass
os.mkdir("out")
writer = logs.Writer("../../escape")
assert writer.folder == os.path.realpath("out/escape"), writer.folder
name = writer.write("ws2_32!send", "3", "ws2_32.dll!send+0x0", b"hello", "")
with open(os.path.join(writer.folder, name), "rb") as f:
    assert f.read() == b"hello"
with open(os.path.join(writer.folder, "index.jsonl")) as f:
    line = json.loads(f.read())
assert line["label"] == "ws2_32!send" and line["cpu"] == "3" and line["length"] == 5 and line["file"] == name == "00001-ws2_32_send.bin", line
print("guest-dbg --log reads the buffers its presets name and writes them")

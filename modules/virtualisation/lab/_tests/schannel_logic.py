"""SChannel's key reading on a made up stretch of lsass' memory, laid out as the published method describes, through the
functions the live reader uses at each stop. Started with the folder of guest-net's code."""
import struct
import sys

sys.path.insert(0, sys.argv[1])
import capture
import schannel


class Memory:
    def __init__(self):
        self.bytes = {}

    def put(self, address, data):
        for i, byte in enumerate(data):
            self.bytes[address + i] = byte

    def pointer(self, address, value):
        self.put(address, struct.pack("<Q", value))

    def read(self, address, size):
        if any(address + i not in self.bytes for i in range(size)):
            raise schannel.Unexpected(f"{size} bytes at {address:#x} could not be read")
        return bytes(self.bytes[address + i] for i in range(size))


def key13(memory, handle, secret):
    """A key of TLS 1.3 behind its handle, by the chain the method follows."""
    memory.put(handle + 4, b"BDDD")
    memory.pointer(handle + 0x10, handle + 0x100)
    memory.pointer(handle + 0x100 + 0x20, handle + 0x200)
    memory.pointer(handle + 0x200 + 0x10, handle + 0x300)
    memory.put(handle + 0x300 + 0x10, struct.pack("<I", len(secret)))
    memory.pointer(handle + 0x300 + 0x18, handle + 0x400)
    memory.put(handle + 0x400, secret)


def hello(memory, address, random):
    memory.put(address, bytes([1, 0, 0, 200, 3, 3]) + random)


memory, secrets = Memory(), schannel.Secrets()
first_random, second_random = bytes(range(32)), bytes(range(100, 132))
master = bytes(range(200, 248))

# TLS 1.2, with the client random in SslGenerateSessionKeys' parameters, after a buffer of another kind.
memory.put(0x1000 + 4, b"BDDD")
memory.pointer(0x1010, 0x2000)
memory.put(0x2000 + 4, b"5lss")
memory.put(0x201C, master)
memory.pointer(0x9000 + 0x28, 0x3000)
memory.put(0x3000, struct.pack("<IIQ", 0, 2, 0x3100))
memory.put(0x3100, struct.pack("<IIQ", 32, 21, 0x3200) + struct.pack("<IIQ", 32, 20, 0x3300))
memory.put(0x3200, bytes(32))
memory.put(0x3300, first_random)
lines = secrets.session_keys({"rdx": 0x1000, "rsp": 0x9000, "gs_base": 7}, memory.read)
assert lines == [f"CLIENT_RANDOM {first_random.hex()} {master.hex()}"], lines

# TLS 1.2 whose parameters lack it: the ClientHello of the same thread gives it, and another thread's does not.
memory.pointer(0x9100 + 0x28, 0)
hello(memory, 0x4000, second_random)
secrets.handshake({"r8": 0x4000, "r9": 300, "gs_base": 8}, memory.read)
assert secrets.session_keys({"rdx": 0x1000, "rsp": 0x9100, "gs_base": 8}, memory.read)[0].split()[1] == second_random.hex()
try:
    secrets.session_keys({"rdx": 0x1000, "rsp": 0x9100, "gs_base": 9}, memory.read)
    raise AssertionError("a thread without a ClientHello got a client random")
except schannel.Unexpected:
    pass

# A message that is no ClientHello leaves the random of its thread alone.
memory.put(0x4100, bytes([2, 0, 0, 80, 3, 3]) + bytes(32))
secrets.handshake({"r8": 0x4100, "r9": 300, "gs_base": 8}, memory.read)
assert secrets.randoms[8] == second_random.hex()

# TLS 1.3: two calls of SslExpandTrafficKeys in a thread, the handshake's secrets and then the traffic's, of 48 and 32 bytes.
hello(memory, 0x4200, first_random)
secrets.handshake({"r8": 0x4200, "r9": 512, "gs_base": 10}, memory.read)
expected = []
for call, (size, suffix) in enumerate([(48, "HANDSHAKE_TRAFFIC_SECRET"), (32, "TRAFFIC_SECRET_0")]):
    rsp, outs = 0xA000 + call * 0x100, 0xB000 + call * 0x100
    memory.pointer(rsp, 0x7FFE0000 + call)
    memory.pointer(rsp + 0x28, outs + 8)
    client, server = bytes([call + 1]) * size, bytes([call + 0x41]) * size
    key13(memory, 0x10000 + call * 0x1000, client)
    key13(memory, 0x20000 + call * 0x1000, server)
    memory.pointer(outs, 0x10000 + call * 0x1000)
    memory.pointer(outs + 8, 0x20000 + call * 0x1000)
    pending = secrets.expand_entry({"r9": outs, "rsp": rsp, "gs_base": 10}, memory.read)
    assert pending["back"] == 0x7FFE0000 + call and pending["rsp"] == rsp + 8, pending
    lines = secrets.expand_return(pending, memory.read)
    assert lines == [f"CLIENT_{suffix} {first_random.hex()} {client.hex()}", f"SERVER_{suffix} {first_random.hex()} {server.hex()}"], lines
    expected += lines

# The next connection of that thread starts with its handshake again.
pending = secrets.expand_entry({"r9": 0xB000, "rsp": 0xA000, "gs_base": 10}, memory.read)
assert secrets.expand_return(pending, memory.read)[0].startswith("CLIENT_HANDSHAKE_TRAFFIC_SECRET")

# A tag that is not where the method expects it is said, and gives no key.
memory.put(0x1000 + 4, b"XXXX")
try:
    secrets.session_keys({"rdx": 0x1000, "rsp": 0x9000, "gs_base": 7}, memory.read)
    raise AssertionError("a key was read behind a wrong tag")
except schannel.Unexpected as e:
    assert "BDDD was expected" in str(e), e

# Every line is one the session takes into a capture.
for line in expected + [f"CLIENT_RANDOM {first_random.hex()} {master.hex()}"]:
    assert capture.KEYLOG.fullmatch(line), line
print("ok: the client random, the TLS 1.2 master key and the TLS 1.3 secrets are found where the method says, by thread")

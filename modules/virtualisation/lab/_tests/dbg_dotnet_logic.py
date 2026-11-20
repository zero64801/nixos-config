"""guest-dbg's places in methods of .NET, on made up memory and a made up debugger. A real assembly, built with the C# compiler
of .NET's SDK, is put in a process's memory both as the runtime keeps one loaded from bytes and as Windows maps one, and
the IL found for each place has to be what .NET's own reflection says. JITs made to the bytes getJit has in .NET Framework
4.8 and in .NET 8 have to lead to their compileMethod, or to the address whose first read brings in what is not in memory
yet. Then the watch has to follow a program from before its JIT is loaded, through getJit and that first read, to each
compile of the method.

usage: dbg_dotnet_logic.py GUEST_DBG_CODE SAMPLE_FOLDER"""
import os
import struct
import sys

sys.path.insert(0, sys.argv[1])
import dotnet

sample = sys.argv[2]
with open(os.path.join(sample, "sample.dll"), "rb") as f:
    assembly = f.read()
with open(os.path.join(sample, "il.txt")) as f:
    reflected = {place: bytes.fromhex(il) for place, il in (line.split() for line in f if line.strip())}
PAGE = 4096


class Memory:
    """A process's memory as pages, those that are not there failing a read as the debugger's do."""

    def __init__(self):
        self.pages = {}

    def put(self, address, data):
        for at in range(len(data)):
            page = self.pages.setdefault((address + at) // PAGE * PAGE, bytearray(PAGE))
            page[(address + at) % PAGE] = data[at]

    def drop(self, address):
        self.pages.pop(address // PAGE * PAGE, None)

    def read(self, address, length):
        out = bytearray()
        for at in range(address, address + length):
            page = self.pages.get(at // PAGE * PAGE)
            if page is None:
                return b""
            out.append(page[at % PAGE])
        return bytes(out)


class Guest:
    """What guest-dbg's Windows has of MemProcFS, for one process, whose reads give zeros where there is nothing."""

    def __init__(self, memory, modules=(), ranges=()):
        self.memory, self.module_list, self.range_list, self.refreshed = memory, list(modules), list(ranges), 0

    def modules(self, pid):
        return self.module_list

    def ranges(self, pid):
        return self.range_list

    def read(self, pid, address, length):
        return self.memory.read(address, length) or bytes(length)

    def refresh(self, pid):
        self.refreshed += 1

    def module(self, pid, name):
        for base, size, found in self.module_list:
            if found.lower() == name.lower():
                return pid, base, size, found
        raise LookupError(name)

    def address(self, pid, module, symbol):
        if (module, symbol) == ("ntdll", "LdrLoadDll"):
            return LOADER
        raise LookupError(symbol)

    def processes(self):
        return [(4, 0, "System")]


def mapped(data):
    """A PE file laid out as Windows maps it: its headers, then each section at its RVA."""
    parts, lfanew = dotnet.sections(data)
    size = struct.unpack_from("<I", data, lfanew + 24 + 56)[0]
    image = bytearray(size)
    headers = struct.unpack_from("<I", data, lfanew + 24 + 60)[0]
    image[:headers] = data[:headers]
    for rva, _, raw, raw_size, _ in parts:
        image[rva: rva + raw_size] = data[raw: raw + raw_size]
    return bytes(image)


def check(condition, what):
    assert condition, what
    print("ok:", what)


# The places' text.
place = dotnet.Place("dotnet:Sample!Lab.Sample+Outer+Inner::Twice/1")
check((place.assembly, place.path, place.method, place.parameters) == ("sample", ("Lab", "Sample", "Outer", "Inner"), "Twice", 1),
      "a place names the assembly, the nested type, the method and how many parameters it takes")
check(dotnet.Place("dotnet:Plain::Run").path == ("", "Plain") and dotnet.Place("dotnet:Plain::Run").assembly == "", "a type without a namespace")
for wrong in ("dotnet:Lab.Sample", "dotnet:::Run", "dotnet:Lab.Sample::", "dotnet:Lab.Sample::Add/two"):
    try:
        dotnet.Place(wrong)
        raise AssertionError(f"{wrong} was taken")
    except ValueError:
        pass
print("ok: a place that names no method is refused")

# The assembly as the runtime keeps one loaded from bytes, at the start of a stretch of its own, and as Windows maps one.
FLAT, MAPPED = 0x1F000000, 0x7FF600000000
memory = Memory()
memory.put(FLAT, assembly)
memory.put(MAPPED, mapped(assembly))
guest = Guest(memory, modules=[(MAPPED, len(mapped(assembly)), "sample.dll")], ranges=[(FLAT, len(assembly)), (0x30000000, PAGE)])
memory.put(0x30000000, b"not an image" + bytes(100))
for text, wanted in (("dotnet:Lab.Sample::Add/2", "Lab.Sample::Add/2"), ("dotnet:Lab.Sample::Add/3", "Lab.Sample::Add/3"),
                     ("dotnet:Lab.Sample::Name", "Lab.Sample::Name/1"), ("dotnet:Lab.Sample+Outer+Inner::Twice", "Lab.Sample+Outer+Inner::Twice/1")):
    found = dotnet.find(guest, 1, dotnet.Place(text))
    check(len(found) == 2 and all(body.il == reflected[wanted] for body in found), f"{text}: the IL reflection gives, from both layouts")
    check(sorted(body.address >= MAPPED for body in found) == [False, True] and all(memory.read(b.address, len(b.il)) == b.il for b in found),
          f"{text}: where the IL is in each layout")
both = dotnet.find(guest, 1, dotnet.Place("dotnet:Lab.Sample::Add"))
check(len(both) == 4 and {body.il for body in both} == {reflected["Lab.Sample::Add/2"], reflected["Lab.Sample::Add/3"]},
      "a method without a parameter count is every one of that name")
check(all(body.label == "sample!Lab.Sample::Add" for body in both), "a body is named by its assembly and its type")
check(dotnet.find(guest, 1, dotnet.Place("dotnet:other!Lab.Sample::Add")) == [], "another assembly's name finds nothing")
check(len(dotnet.find(guest, 1, dotnet.Place("dotnet:sample.dll!Lab.Sample::Add/2"))) == 2, "the module's file name names the assembly too")

# A stretch whose first page is still zeros is looked at again, as the runtime may copy an assembly into it later.
LATER = 0x2F000000
seen = {}
later = Guest(memory, ranges=[(LATER, len(assembly))])
memory.put(LATER, bytes(PAGE))
check(dotnet.find(later, 1, dotnet.Place("dotnet:Lab.Sample::Name"), seen) == [] and LATER not in seen, "a stretch of zeros is not taken as no assembly")
memory.put(LATER, assembly)
check(len(dotnet.find(later, 1, dotnet.Place("dotnet:Lab.Sample::Name"), seen)) == 1, "the assembly copied there later is found")

# JITs made to the bytes of getJit of .NET Framework 4.8 and .NET 8: the first leads its table, the second an object whose
# first word is its table, and the first entry of the table is compileMethod.
# Its exports and its table are on pages of their own, as one can be in memory and not the other.
TEXT, RDATA, DATA = 0x1000, 0x2000, 0x4000
GETJIT, COMPILE, TABLE, OBJECT, OTHER = TEXT + 0x100, TEXT + 0x500, RDATA + 0x1100, DATA + 0x100, DATA + 0x200


def jit(base, framework):
    """A JIT's image at base: its headers, getJit exported, and the table, the object and compileMethod where they are."""
    image = bytearray(0x5000)
    image[0:2], image[0x3C:0x40] = b"MZ", struct.pack("<I", 0x80)
    image[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", image, 0x84, 0x8664, 3)
    struct.pack_into("<H", image, 0x94, 0xF0)
    struct.pack_into("<H", image, 0x98, 0x20B)
    struct.pack_into("<II", image, 0x98 + 112, RDATA + 0x800, 0x100)
    for n, (name, rva, size, flags) in enumerate(((b".text", TEXT, PAGE, 0x60000020), (b".rdata", RDATA, 2 * PAGE, 0x40000040),
                                                   (b".data", DATA, PAGE, 0xC0000040))):
        struct.pack_into("<8sIIII", image, 0x188 + 40 * n, name, size, rva, size, rva)
        struct.pack_into("<I", image, 0x188 + 40 * n + 36, flags)
    exports = RDATA + 0x800
    struct.pack_into("<IIII", image, exports + 20, 1, 1, exports + 0x40, exports + 0x50)
    struct.pack_into("<I", image, exports + 36, exports + 0x60)
    struct.pack_into("<I", image, exports + 0x40, GETJIT)
    struct.pack_into("<I", image, exports + 0x50, exports + 0x70)
    image[exports + 0x70: exports + 0x77] = b"getJit\0"
    struct.pack_into("<QQ", image, TABLE, base + COMPILE, base + COMPILE + 0x80)

    def relative(opcode, at, target):
        return opcode + struct.pack("<i", target - (at + 7))

    if framework:
        code = (relative(b"\x48\x8b\x05", GETJIT, OTHER) + b"\x48\x85\xc0\x75\x1c" + relative(b"\x48\x8d\x05", GETJIT + 12, TABLE)
                + relative(b"\x48\x89\x05", GETJIT + 19, OBJECT) + relative(b"\x48\x8d\x05", GETJIT + 26, OBJECT)
                + relative(b"\x48\x89\x05", GETJIT + 33, OTHER) + b"\xc3")
        struct.pack_into("<Q", image, OBJECT, base + TABLE)
    else:
        code = (b"\x8a\x05" + struct.pack("<i", OTHER - (GETJIT + 6)) + relative(b"\x48\x8d\x0d", GETJIT + 6, OBJECT)
                + b"\xf6\xd8\x48\x1b\xc0\x48\x23\xc1\xc3")
        struct.pack_into("<Q", image, OBJECT, base + TABLE)
    image[GETJIT: GETJIT + len(code)] = code
    image[COMPILE: COMPILE + 3] = b"\x48\x89\x5c"
    return bytes(image)


for framework in (True, False):
    base = 0x7FF940000000
    jits = Memory()
    jits.put(base, jit(base, framework))
    name = ".NET Framework 4.8" if framework else ".NET 8"
    check(dotnet.compile_method(jits.read, base) == (base + COMPILE, None, True), f"{name}: getJit leads to compileMethod")
    jits.drop(base + TABLE)
    check(dotnet.compile_method(jits.read, base) == (None, base + TABLE, True), f"{name}: a table not in memory is the address to wait on")
    if not framework:
        jits.drop(base + OBJECT)
        check(dotnet.compile_method(jits.read, base)[1] == base + OBJECT, f"{name}: so is an object not in memory")
    jits.drop(base + GETJIT)
    check(dotnet.compile_method(jits.read, base, base + GETJIT) == (None, None, False), f"{name}: getJit's code not in memory is said")


class Gdb:
    """The few commands of gdb's MI the watch gives, and the debug registers they take."""

    def __init__(self):
        self.next, self.points = 1, {}

    def run(self, command, wait=30):
        if command.startswith("-break-delete "):
            del self.points[command.split()[1]]
            return {}, None
        number = str(self.next)
        self.next += 1
        address = int(command.rsplit("0x", 1)[1].rstrip('"'), 16)
        if command.startswith("-break-insert -h *"):
            self.points[number] = ("break", address)
            return {"bkpt": {"number": number}}, None
        self.points[number] = ("access", address)
        return {"hw-awpt": {"number": number}}, None

    def at(self, kind, address):
        return next(number for number, point in self.points.items() if point == (kind, address))


class Debugger:
    """What the watch reads at a stop: the process's memory, as gdb reads it."""

    def __init__(self, memory):
        self.memory, self.gdb = memory, Gdb()

    def peek(self, address, length):
        return self.memory.read(address, length)

    def word(self, address):
        return int.from_bytes(self.memory.read(address, 8), "little")


# A program held before its first instruction: no JIT and no assembly yet.
LOADER, JIT_BASE, STACK, NAME, INFO, SLOT, CODE = 0x7FFA00001000, 0x7FF950000000, 0x9F0000, 0xA00000, 0xA10000, 0xA20000, 0x7FF8E0001000
process = Memory()
process.put(FLAT, bytes(PAGE))
held = Guest(process, ranges=[(FLAT, len(assembly))])
debugger = Debugger(process)
watch = dotnet.Watch(debugger, held, 1, dotnet.Place("dotnet:Lab.Sample::Add/3"))
check(watch.look() == [] and "waits for LdrLoadDll" in watch.arm() and list(debugger.gdb.points.values()) == [("break", LOADER)],
      "with no JIT loaded, the watch stops where LdrLoadDll begins")


def stop(number, **registers):
    return watch.stop(number, dict({"rsp": STACK, "rax": 0, "rip": 0, "r8": 0, "r9": 0}, **registers))


def call(at, back, registers):
    """The stack and the registers at a function's first instruction, called from back."""
    process.put(STACK, struct.pack("<Q", back))
    return dict(registers, rsp=STACK, rip=at)


name = "C:\\Program Files\\dotnet\\shared\\Microsoft.NETCore.App\\8.0.8\\clrjit.dll".encode("utf-16-le")
process.put(NAME, struct.pack("<H6xQ", len(name), NAME + 0x100))
process.put(NAME + 0x100, name)
process.put(NAME + 0x80, struct.pack("<H6xQ", 18, NAME + 0x200))
process.put(NAME + 0x200, "other.dll".encode("utf-16-le"))
loading = debugger.gdb.at("break", LOADER)
check(stop(loading, **call(LOADER, 0x7FFA00002000, {"r8": NAME + 0x80, "r9": NAME + 0x300})) == ([], None) and len(debugger.gdb.points) == 1,
      "another DLL's load is let go")
codes, said = stop(loading, **call(LOADER, 0x7FFA00002000, {"r8": NAME, "r9": NAME + 0x300}))
check(("break", 0x7FFA00002000) in debugger.gdb.points.values(), "the JIT's load is waited for where LdrLoadDll returns")
# Loaded, but only its headers and exports are in memory: not getJit's code, nor the table it leads to.
whole = jit(JIT_BASE, True)
process.put(JIT_BASE, whole)
process.drop(JIT_BASE + GETJIT)
process.drop(JIT_BASE + TABLE)
process.put(NAME + 0x300, struct.pack("<Q", JIT_BASE))
codes, said = stop(debugger.gdb.at("break", 0x7FFA00002000), rsp=STACK + 8)
check("getJit" in said and set(debugger.gdb.points.values()) == {("break", JIT_BASE + GETJIT)}, "getJit's code not in memory: a stop where it begins")
process.put(JIT_BASE + GETJIT, whole[GETJIT: GETJIT + 64])
codes, said = stop(debugger.gdb.at("break", JIT_BASE + GETJIT), rip=JIT_BASE + GETJIT)
check("first read" in said and set(debugger.gdb.points.values()) == {("access", JIT_BASE + TABLE)}, "the table not in memory: a stop at its first read")

# The runtime's call reads the table, which brings it in, and leaves the processor at compileMethod: a first compile, of
# a method of an assembly the runtime has only now copied into memory.
process.put(JIT_BASE + TABLE, whole[TABLE: TABLE + 16])
process.put(FLAT, assembly)
body = next(b for b in dotnet.find(held, 1, dotnet.Place("dotnet:Lab.Sample::Add/3")) if b.address < MAPPED)
process.put(INFO, struct.pack("<QQQI", 0x7FF8EA000000, 0x7FF8EB000000, body.address, len(body.il)))
process.put(STACK + dotnet.NATIVE_ENTRY, struct.pack("<Q", SLOT))
codes, said = stop(debugger.gdb.at("access", JIT_BASE + TABLE), **call(JIT_BASE + COMPILE, 0x7FF94A000100, {"r8": INFO}))
check("compileMethod" in said and set(debugger.gdb.points.values()) == {("break", JIT_BASE + COMPILE), ("break", 0x7FF94A000100)},
      "the read that brings the table in is the call's, which is the method's compile, looked for in the assembly loaded since")
check(held.refreshed == 1, "a module the JIT compiles for the first time has MemProcFS look at the process again")
process.put(SLOT, struct.pack("<Q", CODE))
codes, said = stop(debugger.gdb.at("break", 0x7FF94A000100), rsp=STACK + 8)
check(codes == [CODE] and "compiled" in said and set(debugger.gdb.points.values()) == {("break", JIT_BASE + COMPILE)},
      "where the compile returns, the code the JIT wrote is the place's")

# Another method's compile is let go, and the method's next compile, as its second tier, gives its newer code.
process.put(INFO + 0x40, struct.pack("<QQQI", 0x7FF8EA000040, 0x7FF8EB000000, FLAT + 0x9000, len(body.il)))
process.put(FLAT + 0x9000, bytes(len(body.il)))
check(stop(debugger.gdb.at("break", JIT_BASE + COMPILE), **call(JIT_BASE + COMPILE, 0x7FF94A000100, {"r8": INFO + 0x40})) == ([], None)
      and len(debugger.gdb.points) == 1, "another method's compile is let go")
codes, _ = stop(debugger.gdb.at("break", JIT_BASE + COMPILE), **call(JIT_BASE + COMPILE, 0x7FF94A000100, {"r8": INFO}))
process.put(SLOT, struct.pack("<Q", CODE + 0x1000))
codes, said = stop(debugger.gdb.at("break", 0x7FF94A000100), rsp=STACK + 8)
check(codes == [CODE + 0x1000], "a second compile of the method gives its newer code")
codes, _ = stop(debugger.gdb.at("break", JIT_BASE + COMPILE), **call(JIT_BASE + COMPILE, 0x7FF94A000100, {"r8": INFO}))
codes, said = stop(debugger.gdb.at("break", 0x7FF94A000100), rsp=STACK + 8, rax=1)
check(codes == [] and "failed" in said, "a compile that failed gives no code")
check(stop(debugger.gdb.at("break", JIT_BASE + COMPILE), **call(JIT_BASE + COMPILE, 0x7FF94A000100, {"r8": INFO})) == ([], None),
      "the method's compile waits for its return")
check(stop(debugger.gdb.at("break", 0x7FF94A000100), rsp=STACK + 0x100) == ([], None) and watch.pending,
      "a return of another call of the same function, with another stack, is not the compile's")
print("guest-dbg follows the JIT to the code of a method of .NET")

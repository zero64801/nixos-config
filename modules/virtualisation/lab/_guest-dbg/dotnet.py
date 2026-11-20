"""Places in methods of .NET for guest-dbg. The JIT compiles a method when it is first called, so its code has no address
before that. guest-dbg stops where the JIT's compileMethod begins, knows the method by its IL, which the metadata of
the assembly in the process's memory gives, and once the JIT returns sets the place's stop at the code the JIT wrote. A
method compiled again, as .NET does with a hot one at its second tier, has the stop moved to its newest code.

compileMethod is the first entry of the JIT object's table of virtual functions, and getJit, the export the runtime
calls for the JIT, loads that table or that object with a lea of an address in the JIT's own image, in .NET Framework
4.8 and in .NET 8 and 10 alike. No symbols are needed, which .NET Framework's JIT has none of on Microsoft's server.

Without a place, the watch only finds compileMethod, for --log jit, which writes every IL body the JIT is handed, and
names the method whose IL that is in a loaded assembly.

A program held before its first instruction, as guest-exec --job --suspended starts one, has no JIT yet, and nothing but
ntdll, so guest-dbg first stops where ntdll's LdrLoadDll loads a DLL, until it is the JIT. Windows brings a DLL's pages
into memory only as they are used, so the JIT's code may not be there to read yet, and then guest-dbg also stops where
getJit begins, which the runtime calls before it compiles anything.
"""
import logging
import struct

import dnfile
import pefile

# dnfile logs each reference it cannot follow, which a stretch of metadata MemProcFS could not read has many of.
logging.getLogger("dnfile").setLevel(logging.CRITICAL)
BROKEN = (LookupError, dnfile.errors.dnFormatError, pefile.PEFormatError, ValueError, IndexError, AttributeError, TypeError, struct.error)

PREFIX = "dotnet:"
# CORINFO_METHOD_INFO begins with the method's handle, its module's, the IL and the IL's size, in every runtime since .NET Framework 4.
INFO = struct.Struct("<QQQI")
# Windows x64: compileMethod(this, comp, info, flags, nativeEntry, nativeSizeOfCode), the fifth argument above the return
# address and the home space of four.
NATIVE_ENTRY = 0x28
# LdrLoadDll(SearchPath, DllCharacteristics, DllName, BaseAddress) takes the name as a UNICODE_STRING, its length in bytes
# first and its characters' address at 8, and writes the DLL's base where its fourth argument points.
UNICODE_STRING = struct.Struct("<H6xQ")
JIT = "clrjit.dll"
EXECUTE, WRITE = 0x20000000, 0x80000000
# The CLI header's flag of a native image of NGen, whose methods .NET Framework runs as they are and never compiles.
NATIVE_IMAGE = 0x4


class Place:
    """A method as a place: dotnet:[ASSEMBLY!]NAMESPACE.TYPE::METHOD[/PARAMETERS], a nested type after the type it is in
    and a +, PARAMETERS being how many the method takes, for one of several of the same name."""

    def __init__(self, text):
        self.text = text
        assembly, _, rest = text[len(PREFIX):].rpartition("!")
        typename, sep, method = rest.partition("::")
        method, slash, count = method.partition("/")
        if not sep or not typename or not method or (slash and not count.isdigit()):
            raise ValueError(f"{text}: a .NET place is dotnet:[ASSEMBLY!]NAMESPACE.TYPE::METHOD[/PARAMETERS]")
        outer, *nested = typename.split("+")
        namespace, _, name = outer.rpartition(".")
        self.assembly, self.path, self.method = assembly.lower(), (namespace, name, *nested), method
        self.parameters = int(count) if slash else None


class Body:
    """A method's IL as the process has it: its name, where it is, its bytes, and ReadyToRun when that precompiled it."""

    def __init__(self, label, address, il, precompiled):
        self.label, self.address, self.il, self.precompiled = label, address, il, precompiled


def sections(head):
    """(rva, size in memory, offset in the file, size in the file, flags) of each section of a PE header, and where its PE
    signature is, or None when it is not one."""
    if head[:2] != b"MZ" or len(head) < 0x40:
        return None
    lfanew = struct.unpack_from("<I", head, 0x3C)[0]
    if lfanew + 24 > len(head) or head[lfanew: lfanew + 4] != b"PE\0\0":
        return None
    count, optional = struct.unpack_from("<HH", head, lfanew + 6)[0], struct.unpack_from("<H", head, lfanew + 20)[0]
    table = lfanew + 24 + optional
    if table + 40 * count > len(head):
        return None
    out = []
    for i in range(count):
        size, rva, raw_size, raw = struct.unpack_from("<IIII", head, table + 40 * i + 8)
        out.append((rva, size, raw, raw_size, struct.unpack_from("<I", head, table + 40 * i + 36)[0]))
    return out, lfanew


def directory(head, lfanew, number):
    """(rva, size) of a data directory of a PE header."""
    magic = struct.unpack_from("<H", head, lfanew + 24)[0]
    at = lfanew + 24 + (112 if magic == 0x20B else 96) + 8 * number
    return struct.unpack_from("<II", head, at) if at + 8 <= len(head) else (0, 0)


def offset_of(parts, rva):
    for start, size, raw, raw_size, _ in parts:
        if start <= rva < start + max(size, raw_size):
            return raw + rva - start
    return None


class Image:
    """A .NET assembly in a process's memory, mapped as Windows maps an image or flat as a file has it, as the runtime
    keeps one loaded from bytes. Reads go through read(address, length)."""

    def __init__(self, read, base, head, name):
        self.read, self.base, self.name = read, base, name
        self.parts, lfanew = sections(head)
        cli_rva, _ = directory(head, lfanew, 14)
        self.layout = None
        for layout in ("mapped", "flat"):
            self.layout = layout
            cli = self.at_rva(cli_rva, 72)
            metadata = cli and len(cli) == 72 and struct.unpack_from("<I", cli, 0)[0] == 0x48 and self.at_rva(struct.unpack_from("<I", cli, 8)[0], 4)
            if metadata == b"BSJB":
                break
        else:
            raise LookupError("no metadata")
        self.flags, (metadata_rva, metadata_size) = struct.unpack_from("<I", cli, 16)[0], struct.unpack_from("<II", cli, 8)
        if self.flags & NATIVE_IMAGE:
            raise LookupError("a native image of NGen, whose methods the JIT never compiles")
        # A file of zeros but for the headers and the metadata, which is all of it dnfile reads, and less than the whole image.
        end = max(raw + raw_size for _, _, raw, raw_size, _ in self.parts)
        size_of_headers = struct.unpack_from("<I", head, lfanew + 24 + 60)[0]
        data = bytearray(end)
        data[:min(size_of_headers, len(head))] = head[:size_of_headers]
        for rva, size in ((cli_rva, 72), (metadata_rva, metadata_size)):
            at, got = offset_of(self.parts, rva), self.at_rva(rva, size)
            if at is None or got is None or at + size > end:
                raise LookupError("metadata out of its image")
            data[at: at + size] = got
        self.pe = dnfile.dnPE(data=bytes(data))
        names = getattr(self.pe.net.mdtables, "Assembly", None)
        self.assembly = str(names.rows[0].Name) if names and names.rows else name
        self.precompiled = "ReadyToRun" if self.ready_to_run(cli) else None

    def ready_to_run(self, cli):
        rva, _ = struct.unpack_from("<II", cli, 64)
        return bool(rva) and self.at_rva(rva, 4) == b"RTR\0"

    def address(self, rva):
        if self.layout == "mapped":
            return self.base + rva
        at = offset_of(self.parts, rva)
        return None if at is None else self.base + at

    def at_rva(self, rva, length):
        address = self.address(rva)
        return None if address is None else self.read(address, length)

    def types(self):
        """(namespace, name, nested names...) of each type, and its row."""
        tables = self.pe.net.mdtables
        rows = tables.TypeDef.rows if tables.TypeDef else []
        outer = {n.NestedClass.row_index: n.EnclosingClass.row_index for n in (tables.NestedClass.rows if tables.NestedClass else [])
                 if n.NestedClass and n.EnclosingClass}

        def path(index, depth=0):
            row = rows[index - 1]
            if index in outer and depth < 64 and 0 < outer[index] <= len(rows):
                return path(outer[index], depth + 1) + (str(row.TypeName),)
            return (str(row.TypeNamespace or ""), str(row.TypeName))

        for index, row in enumerate(rows, 1):
            yield path(index), row

    def bodies(self, place):
        """The IL of the methods of this assembly the place names."""
        if place.assembly and stem(place.assembly) not in (stem(self.name), stem(self.assembly)):
            return []
        out = []
        for path, row in self.types():
            if path != place.path:
                continue
            for method in row.MethodList or []:
                found = method.row
                if not found or str(found.Name) != place.method or not found.Rva:
                    continue
                if place.parameters is not None and parameters(bytes(getattr(found.Signature, "value", b""))) != place.parameters:
                    continue
                address = self.address(found.Rva)
                il = body(self.read, address) if address else None
                if il is not None:
                    out.append(Body(self.label(path, place.method), il[0], il[1], self.precompiled))
        return out

    def label(self, path, method):
        return f"{self.assembly}!{'.'.join(p for p in path[:2] if p)}{''.join('+' + p for p in path[2:])}::{method}"

    def names(self):
        """{where each method's body begins: its name} of the methods of the assembly that have IL."""
        out = {}
        for path, row in self.types():
            for method in row.MethodList or []:
                found = method.row
                address = self.address(found.Rva) if found and found.Rva else None
                if address:
                    out[address] = self.label(path, str(found.Name))
        return out


def stem(name):
    """An assembly's or a module's name without the .dll or .exe a file of it has."""
    name = name.lower()
    return name[:-4] if name.endswith((".dll", ".exe")) else name


def compressed(data, at):
    """An unsigned integer as ECMA-335 II.23.2 packs it, and where it ends."""
    first = data[at]
    if first < 0x80:
        return first, at + 1
    if first < 0xC0:
        return (first & 0x3F) << 8 | data[at + 1], at + 2
    return (first & 0x1F) << 24 | data[at + 1] << 16 | data[at + 2] << 8 | data[at + 3], at + 4


def parameters(signature):
    """How many parameters a method's signature takes, past its generic parameters' count, or None."""
    try:
        at = 1
        if signature[0] & 0x10:
            _, at = compressed(signature, at)
        return compressed(signature, at)[0]
    except IndexError:
        return None


def body(read, address):
    """(where the IL begins, the IL) of a method body of ECMA-335 II.25.4: a tiny header of one byte, or a fat one of a
    size it says."""
    head = read(address, 12)
    if not head:
        return None
    if head[0] & 3 == 2:
        start, size = address + 1, head[0] >> 2
    elif head[0] & 3 == 3:
        start, size = address + (struct.unpack_from("<H", head, 0)[0] >> 12) * 4, struct.unpack_from("<I", head, 4)[0]
    else:
        return None
    if size > 1 << 24:
        return None
    il = read(start, size) if size else b""
    return (start, il) if il is not None else None


def assemblies(guest, pid, seen):
    """The .NET assemblies of a process: those mapped, which MemProcFS lists as modules, and those loaded from bytes, which
    the runtime puts at the start of a stretch of memory of their own. seen keeps what each start was found to be, so
    that a second look reads only what is new."""
    named = {base: name for base, _, name in guest.modules(pid)}
    for base in sorted(set(named) | {start for start, _ in guest.ranges(pid)}):
        if base in seen:
            continue
        head = guest.read(pid, base, 4096)
        # A stretch whose first page is all zeros may be one the runtime is about to copy an assembly into.
        if head and head.count(0) != len(head):
            seen[base] = None
        parsed = head and sections(head)
        if not parsed or not directory(head, parsed[1], 14)[0]:
            continue
        try:
            seen[base] = Image(lambda address, length: guest.read(pid, address, length), base, head, named.get(base, f"{base:#x}"))
        except BROKEN:
            pass
    return [image for image in seen.values() if image]


def find(guest, pid, place, seen=None):
    """The IL bodies of the process that the place names."""
    out = []
    for image in assemblies(guest, pid, {} if seen is None else seen):
        try:
            out += image.bodies(place)
        except BROKEN:
            continue
    return out


def exports(read, base):
    """{name: address} of what a mapped image exports, as far as its memory can be read."""
    head = read(base, 4096)
    parsed = head and sections(head)
    if not parsed:
        return {}
    rva, size = directory(head, parsed[1], 0)
    table = read(base + rva, size) if rva else None
    if not table or len(table) < 40:
        return {}
    count, functions, names, ordinals = struct.unpack_from("<I", table, 24)[0], *struct.unpack_from("<III", table, 28)

    def number(address, size):
        got = read(address, size)
        return int.from_bytes(got, "little") if got and len(got) == size else None

    out = {}
    for i in range(min(count, 4096)):
        name_rva, ordinal = number(base + names + 4 * i, 4), number(base + ordinals + 2 * i, 2)
        function = number(base + functions + 4 * ordinal, 4) if ordinal is not None else None
        name = (read(base + name_rva, 64) or b"").split(b"\0")[0].decode("latin1") if name_rva is not None else ""
        if name and function is not None:
            out[name] = base + function
    return out


def compile_method(read, base, entry=None):
    """Where the JIT whose image is at base has its compileMethod: the first entry of the table its getJit loads, or of the
    table of the object its getJit loads, whichever a lea in getJit's first bytes names. entry is where getJit is, when
    that is known already. Gives (compileMethod or None, an address whose first read by the runtime brings in what is
    not in memory yet, or None, whether getJit's code could be read)."""
    parsed = sections(read(base, 4096) or b"")
    entry = entry or exports(read, base).get("getJit")
    if not parsed or not entry:
        return None, None, False

    def kind(address):
        for rva, size, _, _, flags in parsed[0]:
            if base + rva <= address < base + rva + size:
                return "code" if flags & EXECUTE else ("data" if flags & WRITE else "constant")
        return None

    def word(address):
        got = read(address, 8)
        return struct.unpack_from("<Q", got)[0] if got and len(got) == 8 else None

    code = read(entry, 64) or b""
    # A table that cannot be read yet is the better one to wait on, being a read nearer the call.
    waits = []
    for at in range(len(code) - 6):
        # lea r64, [rip+disp32]: REX.W, 8D, and a ModRM of mod 00 and r/m 101.
        if not (code[at] in (0x48, 0x4C) and code[at + 1] == 0x8D and code[at + 2] & 0xC7 == 0x05):
            continue
        target = entry + at + 7 + struct.unpack_from("<i", code, at + 3)[0]
        table = target if kind(target) == "constant" else word(target) if kind(target) == "data" else None
        if kind(target) == "data" and table is None:
            waits.append((1, target))
            continue
        if table is None or kind(table) != "constant":
            continue
        first = word(table)
        if first is None:
            waits.append((0, table))
        elif kind(first) == "code":
            return first, None, True
    return None, min(waits)[1] if waits else None, bool(code)


class Watch:
    """Follows the JIT of one process for the methods a place names, through the debugger's own breakpoints: where
    LdrLoadDll loads a DLL while the JIT is not loaded yet, then where compileMethod begins, and each time where a call of
    it returns. stop() gives the address of the code of each compile of the method."""

    def __init__(self, debugger, guest, pid, place):
        self.debugger, self.guest, self.pid, self.place = debugger, guest, pid, place
        self.bodies, self.scopes, self.roles, self.pending, self.seen = [], set(), {}, None, {}
        self.jit = self.entry = self.at = None
        self.names, self.named, self.handed = {}, set(), False

    def look(self):
        """The method's IL bodies in what the process has loaded so far."""
        self.bodies = find(self.guest, self.pid, self.place, self.seen)
        return self.bodies

    def insert(self, address, role):
        values, _ = self.debugger.gdb.run(f"-break-insert -h *{address:#x}")
        self.roles[values["bkpt"]["number"]] = role
        return values["bkpt"]["number"]

    def wait_on(self, address):
        """Stops when anything reads or writes the eight bytes at the address."""
        self.remove("access")
        values, _ = self.debugger.gdb.run(f'-break-watch -a "*(unsigned long long *){address:#x}"')
        self.roles[(values.get("hw-awpt") or values.get("wpt"))["number"]] = "access"

    def remove(self, role):
        for number in [n for n, r in self.roles.items() if r == role]:
            self.debugger.gdb.run(f"-break-delete {number}")
            del self.roles[number]

    def arm(self):
        """Stops where compileMethod begins, or where LdrLoadDll does until the JIT is loaded. Gives what stop() gives."""
        try:
            _, base, _, _ = self.guest.module(self.pid, JIT)
        except LookupError:
            self.insert(self.loader(), "load")
            return [], "the JIT is not loaded yet, so this waits for LdrLoadDll to load it"
        self.at, _, _ = compile_method(lambda address, length: self.guest.read(self.pid, address, length), base)
        if self.at is None:
            raise LookupError(f"{JIT} at {base:#x} has no getJit that leads to its compileMethod")
        if self.place:
            self.insert(self.at, "compile")
        return self.hand(), f"compileMethod of {JIT} at {self.at:#x}"

    def hand(self):
        """compileMethod, once it is known, as the code of --log jit, which has no place of its own."""
        if self.place or not self.at or self.handed:
            return []
        self.handed = True
        return [self.at]

    def name(self, il, scope):
        """The name of the method whose IL begins at il, in the assemblies the process has loaded, after a header of one byte or
        of twelve. A module the JIT has not compiled for before has the process looked at again. None for IL that is in no
        assembly, as a protector that decrypts methods hands it."""
        if scope not in self.scopes:
            self.scopes.add(scope)
            self.guest.refresh(self.pid)
            assemblies(self.guest, self.pid, self.seen)
        for base, image in self.seen.items():
            if image and base not in self.named:
                self.named.add(base)
                try:
                    self.names.update(image.names())
                except BROKEN:
                    continue
        return self.names.get(il - 1) or self.names.get(il - 12)

    def loader(self):
        """Where ntdll has LdrLoadDll, which is the same in every process, so another's tells when this one is too new
        for MemProcFS to list its modules."""
        for pid in [self.pid] + [p for p, _, _ in self.guest.processes() if p != self.pid]:
            try:
                return self.guest.address(pid, "ntdll", "LdrLoadDll")
            except LookupError:
                continue
        raise LookupError("no process has an ntdll with LdrLoadDll")

    def owns(self, number):
        return number in self.roles

    def resolve(self, entry=None):
        """Stops where compileMethod begins once what leads to it can be read: until then where getJit begins, while its
        code is not in memory, or where the runtime first reads the table or the object getJit names, which brings that in,
        or at the next DLL that loads, while not even the JIT's exports are in memory. Says which."""
        self.entry = entry or self.entry or exports(self.debugger.peek, self.jit).get("getJit")
        if not self.entry:
            return f"{JIT} loaded at {self.jit:#x}, and its exports are not in memory yet, so the next DLL's load looks again"
        self.at, wanted, readable = compile_method(self.debugger.peek, self.jit, self.entry)
        if self.at:
            for role in ("load", "getjit", "access"):
                self.remove(role)
            if self.place:
                self.insert(self.at, "compile")
            return f"{JIT} at {self.jit:#x} has its compileMethod at {self.at:#x}"
        self.remove("load")
        if wanted is not None:
            self.remove("getjit")
            self.wait_on(wanted)
            return f"{JIT} at {self.jit:#x} has what leads to its compileMethod at {wanted:#x}, which is not in memory yet, so this waits for the first read of it"
        if not readable and "getjit" not in self.roles.values():
            self.insert(self.entry, "getjit")
            return f"{JIT} at {self.jit:#x} has its getJit at {self.entry:#x}, whose code is not in memory yet, so this stops where it begins"
        return f"{JIT} at {self.jit:#x} has a getJit at {self.entry:#x} that leads to no compileMethod"

    def compiled(self, regs):
        """At compileMethod's first instruction: when the method compiled is the place's, waits for the compile to return."""
        raw = self.debugger.peek(regs["r8"], INFO.size)
        if len(raw) < INFO.size:
            return
        _, scope, il, size = INFO.unpack(raw)
        if not self.bodies and scope not in self.scopes:
            # A module the JIT has not compiled for before may be the assembly the method is in, loaded since the last look.
            self.scopes.add(scope)
            self.guest.refresh(self.pid)
            self.look()
        if any(b.address == il or (len(b.il) == size and self.debugger.peek(il, size) == b.il) for b in self.bodies):
            self.returning(regs, "compile", self.debugger.word(regs["rsp"] + NATIVE_ENTRY))

    def returning(self, regs, *rest):
        number = self.insert(self.debugger.word(regs["rsp"]), "return")
        self.pending = (number, regs["rsp"] + 8, *rest)

    def stop(self, number, regs):
        """What a stop at one of the watch's breakpoints means: the addresses of the code of a compile of the method that just
        returned, and a line to say, if any."""
        role = self.roles.get(number)
        if role == "getjit":
            said = self.resolve(regs["rip"])
            return self.hand(), said
        if role == "access":
            said = self.resolve()
            # The read may have been the call's own, which leaves the processor at compileMethod's first instruction.
            if self.place and self.at and regs["rip"] == self.at and self.pending is None:
                self.compiled(regs)
            return self.hand(), said
        if role == "load" and self.jit:
            said = self.resolve()
            return self.hand(), said
        if role == "load" and self.pending is None:
            raw = self.debugger.peek(regs["r8"], UNICODE_STRING.size) if regs.get("r8") else b""
            length, characters = UNICODE_STRING.unpack(raw) if len(raw) == UNICODE_STRING.size else (0, 0)
            name = self.debugger.peek(characters, min(length, 1024)).decode("utf-16-le", "replace") if length and characters else ""
            if name.lower().replace("/", "\\").rsplit("\\", 1)[-1] == JIT:
                self.returning(regs, "load", regs["r9"])
            return [], None
        if role == "compile" and self.pending is None:
            self.compiled(regs)
            return [], None
        if role != "return" or not self.pending or regs["rsp"] != self.pending[1]:
            return [], None
        self.remove("return")
        kind, *rest = self.pending[2:]
        self.pending = None
        if kind == "load":
            self.jit = self.debugger.word(rest[0]) if not regs["rax"] & 0xFFFFFFFF else None
            said = self.resolve() if self.jit else None
            return self.hand(), said
        if regs["rax"] & 0xFFFFFFFF:
            return [], f"the JIT failed to compile {self.place.text}"
        code = self.debugger.word(rest[0])
        return [code], f"the JIT compiled {self.place.text} to {code:#x}"

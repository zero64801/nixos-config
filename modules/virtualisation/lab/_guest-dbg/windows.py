"""What MemProcFS knows of a Windows guest: its processes, their page table roots, modules, exports and symbols."""
import ctypes
import os

PATH = 260
INFORMATION_MAGIC = 0xC0FFEE663DF9301E


# The start of the process information, up to the page table roots. What follows has a size only the library knows.
class Information(ctypes.Structure):
    _fields_ = [("magic", ctypes.c_uint64), ("wVersion", ctypes.c_uint16), ("wSize", ctypes.c_uint16), ("tpMemoryModel", ctypes.c_int32),
                ("tpSystem", ctypes.c_int32), ("fUserOnly", ctypes.c_int32), ("dwPID", ctypes.c_uint32), ("dwPPID", ctypes.c_uint32),
                ("dwState", ctypes.c_uint32), ("szName", ctypes.c_char * 16), ("szNameLong", ctypes.c_char * 64), ("paDTB", ctypes.c_uint64),
                ("paDTB_UserOpt", ctypes.c_uint64)]


class ModuleEntry(ctypes.Structure):
    _fields_ = [("vaBase", ctypes.c_uint64), ("vaEntry", ctypes.c_uint64), ("cbImageSize", ctypes.c_uint32), ("fWoW64", ctypes.c_int32),
                ("uszText", ctypes.c_char_p), ("_Reserved3", ctypes.c_uint32), ("_Reserved4", ctypes.c_uint32), ("uszFullName", ctypes.c_char_p),
                ("tp", ctypes.c_uint32), ("cbFileSizeRaw", ctypes.c_uint32), ("cSection", ctypes.c_uint32), ("cEAT", ctypes.c_uint32),
                ("cIAT", ctypes.c_uint32), ("_Reserved2", ctypes.c_uint32), ("_Reserved1", ctypes.c_uint64 * 3),
                ("pExDebugInfo", ctypes.c_void_p), ("pExVersionInfo", ctypes.c_void_p)]


class ModuleMap(ctypes.Structure):
    _fields_ = [("dwVersion", ctypes.c_uint32), ("_Reserved1", ctypes.c_uint32 * 5), ("pbMultiText", ctypes.c_void_p),
                ("cbMultiText", ctypes.c_uint32), ("cMap", ctypes.c_uint32)]


class PteEntry(ctypes.Structure):
    _fields_ = [("vaBase", ctypes.c_uint64), ("cPages", ctypes.c_uint64), ("fPage", ctypes.c_uint64), ("fWoW64", ctypes.c_uint32),
                ("_FutureUse1", ctypes.c_uint32), ("uszText", ctypes.c_char_p), ("_Reserved1", ctypes.c_uint32), ("cSoftware", ctypes.c_uint32)]


class PteMap(ctypes.Structure):
    _fields_ = [("dwVersion", ctypes.c_uint32), ("_Reserved1", ctypes.c_uint32 * 5), ("pbMultiText", ctypes.c_void_p),
                ("cbMultiText", ctypes.c_uint32), ("cMap", ctypes.c_uint32)]


# From vmmdll.h: the page table map's version, the refresh of one process, by its number in the low half, and of the page
# tables, without which MemProcFS keeps the maps it made first and misses what was mapped since, and reads that go to the
# memory itself and give zeros for what is not there instead of reading the guest's page file.
PTE_VERSION, REFRESH_PROCESS, REFRESH_TLB, READ = 2, 0x2002000300000000, 0x2001080000000000, 0x0001 | 0x0002 | 0x0010


class Windows:
    def __init__(self, library, device):
        self.vmm = vmm = ctypes.CDLL(library)
        vmm.VMMDLL_Initialize.restype = ctypes.c_void_p
        vmm.VMMDLL_ProcessGetProcAddressU.restype = ctypes.c_uint64
        vmm.VMMDLL_ProcessGetProcAddressU.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_char_p]
        vmm.VMMDLL_PdbLoad.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint64, ctypes.c_char_p]
        vmm.VMMDLL_PdbSymbolAddress.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint64)]
        vmm.VMMDLL_PdbSymbolName.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32)]
        vmm.VMMDLL_PidGetFromName.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32)]
        vmm.VMMDLL_ProcessGetInformation.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
        vmm.VMMDLL_Map_GetModuleU.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32]
        vmm.VMMDLL_Map_GetPteU.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(PteMap))]
        vmm.VMMDLL_MemReadEx.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_uint32,
                                         ctypes.POINTER(ctypes.c_uint32), ctypes.c_uint64]
        vmm.VMMDLL_ConfigSet.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64]
        arguments = [b"", b"-device", device.encode(), b"-disable-python"]
        # Symbols come through the lab's gateway, and without it MemProcFS would wait on a network there is none of.
        if not os.environ.get("PDBCRUST_SYMBOL_SOCKET"):
            arguments.append(b"-disable-symbolserver")
        self.handle = ctypes.c_void_p(vmm.VMMDLL_Initialize(len(arguments), (ctypes.c_char_p * len(arguments))(*arguments)))
        if not self.handle:
            raise LookupError("MemProcFS could not make sense of the guest's memory, which it can only for a Windows guest")
        self.symbols = {}
        self.module_lists = {}

    def pid(self, process):
        if process.isdigit():
            return int(process)
        pid = ctypes.c_uint32()
        if not self.vmm.VMMDLL_PidGetFromName(self.handle, process.encode(), ctypes.byref(pid)):
            raise LookupError(f"there is no process named {process}")
        return pid.value

    def information(self, pid):
        """The name, the parent's number and the page table roots of a process, the last of which only some systems have two of."""
        size = ctypes.c_size_t(0)
        self.vmm.VMMDLL_ProcessGetInformation(self.handle, pid, None, ctypes.byref(size))
        buffer = ctypes.create_string_buffer(max(size.value, ctypes.sizeof(Information)))
        info = Information.from_buffer(buffer)
        info.magic, info.wVersion, info.wSize = INFORMATION_MAGIC, 7, size.value
        if not size.value or not self.vmm.VMMDLL_ProcessGetInformation(self.handle, pid, buffer, ctypes.byref(size)):
            raise LookupError(f"there is no process {pid}")
        name = (info.szNameLong or info.szName).decode("latin1")
        return name, info.dwPPID, {root for root in (info.paDTB, info.paDTB_UserOpt) if root}

    def process(self, pid):
        """The name and the page table roots of a process."""
        name, _, roots = self.information(pid)
        return name, roots

    def pids(self):
        count = ctypes.c_size_t(0)
        self.vmm.VMMDLL_PidList(self.handle, None, ctypes.byref(count))
        pids = (ctypes.c_uint32 * count.value)()
        if not self.vmm.VMMDLL_PidList(self.handle, pids, ctypes.byref(count)):
            return []
        return list(pids[:count.value])

    def processes(self):
        """(number, parent's number, name) of every process."""
        out = []
        for pid in self.pids():
            try:
                name, parent, _ = self.information(pid)
            except LookupError:
                continue
            out.append((pid, parent, name))
        return out

    def owners(self):
        """The process of each page table root."""
        out = {}
        for pid in self.pids():
            try:
                name, roots = self.process(pid)
            except LookupError:
                continue
            for root in roots:
                out[root & 0x000FFFFFFFFFF000] = f"{name} {pid}"
        return out

    def modules(self, pid):
        """(base, size, name) of the modules of a process, and with pid 4 of the kernel's."""
        if pid in self.module_lists:
            return self.module_lists[pid]
        pointer = ctypes.POINTER(ModuleMap)()
        out = []
        if self.vmm.VMMDLL_Map_GetModuleU(self.handle, pid, ctypes.byref(pointer), 0):
            header = pointer.contents
            if header.dwVersion != 6:
                raise LookupError(f"the module map has version {header.dwVersion}, not the one this was written for")
            entries = ctypes.cast(ctypes.addressof(header) + ctypes.sizeof(ModuleMap), ctypes.POINTER(ModuleEntry))
            out = [(entries[i].vaBase, entries[i].cbImageSize, entries[i].uszText.decode("utf-8", "replace")) for i in range(header.cMap)]
            self.vmm.VMMDLL_MemFree(pointer)
        self.module_lists[pid] = out
        return out

    def read(self, pid, address, length):
        """length bytes of a process's memory, with zeros for its pages that are not there."""
        buffer, done = ctypes.create_string_buffer(length), ctypes.c_uint32()
        self.vmm.VMMDLL_MemReadEx(self.handle, pid, address, buffer, length, ctypes.byref(done), READ)
        return buffer.raw if done.value else None

    def ranges(self, pid):
        """(start, size) of each stretch of a process's memory that its page tables map alike."""
        pointer = ctypes.POINTER(PteMap)()
        out = []
        if self.vmm.VMMDLL_Map_GetPteU(self.handle, pid, 0, ctypes.byref(pointer)):
            header = pointer.contents
            if header.dwVersion != PTE_VERSION:
                raise LookupError(f"the page table map has version {header.dwVersion}, not the one this was written for")
            entries = ctypes.cast(ctypes.addressof(header) + ctypes.sizeof(PteMap), ctypes.POINTER(PteEntry))
            out = [(entries[i].vaBase, entries[i].cPages * 4096) for i in range(header.cMap)]
            self.vmm.VMMDLL_MemFree(pointer)
        return out

    def refresh(self, pid):
        """Makes MemProcFS look at a process again, for what it loaded since."""
        self.vmm.VMMDLL_ConfigSet(self.handle, REFRESH_TLB, 1)
        self.vmm.VMMDLL_ConfigSet(self.handle, REFRESH_PROCESS | pid, 1)
        self.module_lists.pop(pid, None)

    def module(self, pid, name):
        """(pid that has it, base, size, name) of a module of the process, or of the kernel."""
        wanted = "ntoskrnl.exe" if name.lower() == "nt" else name.lower()
        for owner in (pid, 4) if pid else (4,):
            for base, size, found in self.modules(owner):
                if found.lower() == wanted or found.lower().rsplit(".", 1)[0] == wanted:
                    return owner, base, size, found
        raise LookupError(f"there is no module named {name}")

    def _pdb(self, owner, base):
        if (owner, base) not in self.symbols:
            name = ctypes.create_string_buffer(PATH)
            self.symbols[(owner, base)] = name.value if self.vmm.VMMDLL_PdbLoad(self.handle, owner, base, name) else None
        return self.symbols[(owner, base)]

    def address(self, pid, module, symbol):
        """Where an exported function or a symbol of a module is."""
        owner, base, _, found = self.module(pid, module)
        exported = self.vmm.VMMDLL_ProcessGetProcAddressU(self.handle, owner, found.encode(), symbol.encode())
        if exported:
            return exported
        pdb = self._pdb(owner, base)
        at = ctypes.c_uint64()
        if pdb and self.vmm.VMMDLL_PdbSymbolAddress(self.handle, pdb, symbol.encode(), ctypes.byref(at)):
            return at.value
        raise LookupError(f"{found} neither exports {symbol} nor has it among its symbols"
                          + ("" if pdb else ", and its symbols could not be loaded"))

    def name(self, pid, address):
        """module!symbol+offset, or module+offset, for an address of the process or the kernel."""
        for owner in (pid, 4) if pid else (4,):
            for base, size, found in self.modules(owner):
                if base <= address < base + size:
                    pdb = self._pdb(owner, base)
                    symbol = ctypes.create_string_buffer(PATH)
                    displacement = ctypes.c_uint32()
                    if pdb and self.vmm.VMMDLL_PdbSymbolName(self.handle, pdb, address, symbol, ctypes.byref(displacement)):
                        return f"{found}!{symbol.value.decode('latin1')}+{displacement.value:#x}"
                    return f"{found}+{address - base:#x}"
        return None

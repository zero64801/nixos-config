"""Writes a marker into guest memory through LeechCore and reads it back, at each address given."""
import ctypes
import os
import sys

MAX_PATH = 260


class Config(ctypes.Structure):
    _fields_ = [
        ("dwVersion", ctypes.c_uint32),
        ("dwPrintfVerbosity", ctypes.c_uint32),
        ("szDevice", ctypes.c_char * MAX_PATH),
        ("szRemote", ctypes.c_char * MAX_PATH),
        ("pfn_printf_opt", ctypes.c_void_p),
        ("paMax", ctypes.c_uint64),
        ("fVolatile", ctypes.c_int),
        ("fWritable", ctypes.c_int),
        ("fRemote", ctypes.c_int),
        ("fRemoteDisableCompress", ctypes.c_int),
        ("szDeviceName", ctypes.c_char * MAX_PATH),
    ]


lib = ctypes.CDLL(sys.argv[1])
lib.LcCreate.restype = ctypes.c_void_p
lib.LcCreate.argtypes = [ctypes.POINTER(Config)]
for call in (lib.LcRead, lib.LcWrite):
    call.restype = ctypes.c_int
    call.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint32, ctypes.c_char_p]

config = Config(dwVersion=0xC0FD0002, dwPrintfVerbosity=3, szDevice=os.environ["VM_INSPECT_DEVICE"].encode())
handle = lib.LcCreate(ctypes.byref(config))
if not handle:
    sys.exit("LeechCore did not open the guest")
for word in sys.argv[2:]:
    address, marker = word.split("=")
    address, marker = int(address, 16), marker.encode()
    if not lib.LcWrite(handle, address, len(marker), marker):
        sys.exit(f"write at {address:#x} failed")
    # LeechCore's contiguous read fails below a page, so a whole one is read.
    seen = ctypes.create_string_buffer(0x1000)
    if not lib.LcRead(handle, address, 0x1000, seen) or seen.raw[:len(marker)] != marker:
        sys.exit(f"read at {address:#x} gave {seen.raw[:len(marker)]!r}")
print("probe ok")

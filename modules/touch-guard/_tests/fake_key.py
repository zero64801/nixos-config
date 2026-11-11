"""A stand-in security key on /dev/uhid: asks for a touch on any CTAP2 request, then answers it."""
import os
import struct
import sys
import threading
import time

CREATE2, INPUT2, OUTPUT, SET_REPORT, SET_REPORT_REPLY = 11, 12, 6, 13, 14
DESCRIPTOR = bytes.fromhex("06d0f10901a1010920150026ff007508954081020921150026ff00750895409102c0")
WAIT = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0

fd = os.open("/dev/uhid", os.O_RDWR)
os.write(fd, struct.pack("<I128s64s64sHHIIII4096s", CREATE2, b"Fake Security Key", b"", b"", len(DESCRIPTOR), 3, 0x1050, 0x0407, 0, 0, DESCRIPTOR))


def send(report):
    os.write(fd, struct.pack("<IH4096s", INPUT2, 64, report.ljust(64, b"\0")))


def answer(cid):
    end = time.monotonic() + WAIT
    while time.monotonic() < end:
        send(cid + bytes([0xBB, 0, 1, 2]))
        time.sleep(0.1)
    send(cid + bytes([0x90, 0, 1, 0]))


def request(data):
    if len(data) == 65:
        data = data[1:]
    if len(data) >= 5 and data[4] == 0x90:
        threading.Thread(target=answer, args=(data[:4],), daemon=True).start()


while True:
    event = os.read(fd, 4380)
    kind = struct.unpack_from("<I", event)[0]
    if kind == OUTPUT:
        size = struct.unpack_from("<H", event, 4 + 4096)[0]
        request(event[4:4 + size])
    elif kind == SET_REPORT:
        ident, _, _, size = struct.unpack_from("<IBBH", event, 4)
        request(event[12:12 + size])
        os.write(fd, struct.pack("<IIH", SET_REPORT_REPLY, ident, 0))

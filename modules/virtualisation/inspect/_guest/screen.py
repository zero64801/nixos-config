"""A picture of the guest's screen, or of one of its windows.

The screen comes from QEMU when QEMU draws it. A guest whose display is a card passed through to it has no such
picture, and when it shares frames through Looking Glass the newest of those is read from their memory instead.
Both are taken from outside the guest, so nothing in it decides what they show. One window is another matter: only
the guest can draw that, so it is a picture the guest made.
"""
import array
import fcntl
import itertools
import math
import mmap
import os
import re
import secrets
import socket
import struct
import subprocess
import sys
import time
import zlib

import programs
from agent import Guest, plain
from session import Refused, ask, carried, control_socket, fail, session_folder

PICTURE = 256 * 1024 * 1024
PNG = b"\x89PNG\r\n\x1a\n"
# A window's picture as the helper in the guest writes it: a mark, the width and the height, then rows of blue, green and red.
# 64 MiB of it is a window larger than any screen.
RAW, WINDOW = struct.Struct("<8sII"), 64 * 1024 * 1024

# Looking Glass, as its source lays the shared memory out for LGMP 12 and KVMFR 34.
# Every field below sits where those versions put it, so any other version is refused before something is read from the wrong place.
LGMP_MAGIC, LGMP_VERSION, KVMFR_MAGIC, KVMFR_VERSION = 0x504d474c, 12, b"KVMFR---", 34
# magic, version, session, number of queues, size of the user data, which starts with KVMFR's own header.
LGMP = struct.Struct("<5I")
LGMP_AT, KVMFR_AT = 9664, 9684
QUEUES_AT, QUEUE_SIZE, QUEUE_MAX = 64, 1600, 6
# Within a queue: who is subscribed, then its id, the length of its ring and where the ring is.
QUEUE_SUBS, QUEUE_RING = 192, 296
# user data, size and place of what a message points at. A message is 32 bytes.
MESSAGE, MESSAGE_SIZE = struct.Struct("<QII"), 32
# The frame queue and the two that deliver frames to one client each.
FRAME_QUEUES = (2, 3, 4)
# version, serial, type, screen width and height, data width and height, frame width and height, rotation, stride, pitch, where the pixels' own header is, flags, damage count, and the brightness of plain white in nits.
FRAME = struct.Struct("<16I")
BGRA, RGBA, RGBA10, RGBA16F, BGR_32, RGB_24 = 1, 2, 3, 4, 5, 6
# Bytes a pixel.
# BGR_32 is three as well: its name is for the 32 bit surface the 24 bit pixels are packed into, which is why its data is narrower than its frame.
PIXEL = {BGRA: 4, RGBA: 4, RGBA10: 4, RGBA16F: 8, BGR_32: 3, RGB_24: 3}
TRUNCATED, HDR_PQ = 0x4, 0x10
# What turns light in the wide colours an HDR screen is sent in (BT.2020) into the colours of a plain picture (BT.709), in 1024ths.
# Each row adds up to 1024, so white stays white.
WIDE_TO_PLAIN = ((1701, -602, -75), (-128, 1160, -8), (-19, -103, 1146))
# _IO('u', 0x44) of the kvmfr device, whose size a file status does not tell.
KVMFR_GETSIZE = 0x7544


def png(width, height, rows):
    """A PNG of 8 bit RGB rows, since QEMU's own format is one few programs open."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    packer = zlib.compressobj(6)
    packed = b"".join(packer.compress(b"\0" + row) for row in rows) + packer.flush()
    return PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", packed) + chunk(b"IEND", b"")


def png_rows(data, width, height, step):
    """The rows of a PNG as QEMU writes one, as 8 bit RGB. Only a picture that is to be cut needs them."""
    packed, at = [], 8
    while at + 12 <= len(data):
        size, kind = struct.unpack_from(">I4s", data, at)
        if kind == b"IDAT":
            packed.append(data[at + 8:at + 8 + size])
        at += size + 12
    try:
        raw = zlib.decompress(b"".join(packed))
    except zlib.error:
        raw = b""
    wide = width * step
    if len(raw) != height * (wide + 1):
        fail("the guest's screen came as a picture that is not whole")
    above = bytes(wide)
    for y in range(height):
        kind, row = raw[y * (wide + 1)], bytearray(raw[y * (wide + 1) + 1:(y + 1) * (wide + 1)])
        # Each row was stored as its difference from the pixel to the left, the row above, or a guess from both.
        if kind == 1:
            for n in range(step, wide):
                row[n] = (row[n] + row[n - step]) & 255
        elif kind == 2:
            row = bytearray((value + over) & 255 for value, over in zip(row, above))
        elif kind == 3:
            for n in range(wide):
                row[n] = (row[n] + (((row[n - step] if n >= step else 0) + above[n]) >> 1)) & 255
        elif kind == 4:
            for n in range(wide):
                left, over, corner = (row[n - step], above[n], above[n - step]) if n >= step else (0, above[n], 0)
                guess = left + over - corner
                near = left if abs(guess - left) <= abs(guess - over) and abs(guess - left) <= abs(guess - corner) else over if abs(guess - over) <= abs(guess - corner) else corner
                row[n] = (row[n] + near) & 255
        elif kind != 0:
            fail("the guest's screen came as a picture that is not whole")
        above = row
        if step == 3:
            yield bytes(row)
        else:
            out = bytearray(width * 3)
            for colour in range(3):
                out[colour::3] = row[colour::4]
            yield bytes(out)


def drawn_by_qemu():
    """The screen as QEMU draws it: its size, its rows, and the PNG itself when QEMU answered with one, as a newer one does."""
    data = carried(*ask(control_socket(), {"do": "shot"}), PICTURE)
    if data.startswith(PNG) and data[12:16] == b"IHDR":
        width, height, depth, kind, _, _, laced = struct.unpack(">IIBBBBB", data[16:29])
        plain_rows = depth == 8 and kind in (2, 6) and not laced and 0 < width <= 16384 and 0 < height <= 16384
        return width, height, png_rows(data, width, height, 3 if kind == 2 else 4) if plain_rows else None, data
    fields, start = data[:64].split(maxsplit=4), 0
    if len(fields) == 5 and fields[0] == b"P6" and fields[1].isdigit() and fields[2].isdigit() and fields[3] == b"255":
        width, height = int(fields[1]), int(fields[2])
        # One byte of white space ends the header, whatever stood between its four fields.
        for field in fields[:4]:
            start = data.index(field, start) + len(field)
        start += 1
        if 0 < width <= 16384 and 0 < height <= 16384 and len(data) - start >= width * height * 3:
            return width, height, (data[start + y * width * 3:start + (y + 1) * width * 3] for y in range(height)), None
    fail("the guest's screen came in a format this does not know")


def shared_frames(path):
    """The memory a Looking Glass host in the guest writes its frames to, mapped for reading."""
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.connect(path)
        with conn:
            _, descriptors, _, _ = socket.recv_fds(conn, 1, 1)
    except OSError:
        descriptors = []
    if not descriptors:
        fail("the session did not hand out the memory Looking Glass shares frames through")
    try:
        size = os.fstat(descriptors[0]).st_size or fcntl.ioctl(descriptors[0], KVMFR_GETSIZE)
        return mmap.mmap(descriptors[0], size, mmap.MAP_SHARED, mmap.PROT_READ)
    except (OSError, ValueError) as e:
        fail(f"the memory Looking Glass shares frames through cannot be read: {e}")
    finally:
        os.close(descriptors[0])


def frame_queues(memory):
    """Where each queue that carries frames starts, after checking that the memory is laid out the way this reads it."""
    magic, version, _, queues, _ = LGMP.unpack_from(memory, LGMP_AT)
    if magic != LGMP_MAGIC:
        fail("nothing in the guest has set Looking Glass up, so its host program is not running there")
    kvmfr = struct.unpack_from("<I", memory, KVMFR_AT + 8)[0]
    if version != LGMP_VERSION or memory[KVMFR_AT:KVMFR_AT + 8] != KVMFR_MAGIC or kvmfr != KVMFR_VERSION:
        fail(f"the guest's Looking Glass speaks LGMP {version} and KVMFR {kvmfr}, this reads {LGMP_VERSION} and {KVMFR_VERSION}")
    beat, waited = memory[:8], 0
    # The host program renews this four times a second for as long as it runs.
    while memory[:8] == beat:
        if waited >= 16:
            fail("the Looking Glass host program in the guest has stopped")
        time.sleep(0.05)
        waited += 1
    found = [QUEUES_AT + n * QUEUE_SIZE for n in range(min(queues, QUEUE_MAX))]
    found = [at for at in found if struct.unpack_from("<I", memory, at + QUEUE_RING)[0] in FRAME_QUEUES]
    watched = False
    for at in found:
        subs = struct.unpack_from("<I", memory, at + QUEUE_SUBS)[0]
        watched = watched or bool((subs >> 16) & ~subs & 0xffff)
    if not watched:
        fail("Looking Glass captures the guest's screen only while its client shows it, and none is open")
    return found


def newest_frame(memory, queues):
    """The newest frame that is written out in full: its fields and where its pixels are. None while there is none."""
    best = None
    for at in queues:
        _, length, ring = struct.unpack_from("<3I", memory, at + QUEUE_RING)
        for n in range(min(length, 64)):
            place = ring + n * MESSAGE_SIZE
            if place + MESSAGE_SIZE > len(memory):
                break
            _, _, start = MESSAGE.unpack_from(memory, place)
            if not 0 < start <= len(memory) - FRAME.size:
                continue
            fields = FRAME.unpack_from(memory, start)
            serial, kind, height, pitch, pixels = fields[1], fields[2], fields[6], fields[11], start + fields[12]
            if not (0 < kind <= RGB_24 and 0 < fields[7] <= 16384 and 0 < fields[8] <= 16384 and 0 < height * pitch):
                continue
            if pixels + 4 + height * pitch > len(memory):
                continue
            # The count of bytes written so far stands right before the pixels.
            if struct.unpack_from("<I", memory, pixels)[0] >= height * pitch and (best is None or serial > best[0][1]):
                best = (fields, start, pixels)
    return best


def screen_curve(light):
    """The 8 bit value a plain picture stores for an amount of light from 0 to 1."""
    light = min(max(light, 0.0), 1.0)
    return round(255 * (light * 12.92 if light <= 0.0031308 else 1.055 * light ** (1 / 2.4) - 0.055))


def hdr_tables(white):
    """For a 10 bit HDR value its light, and for a mixed sum of lights the 8 bit value of a plain picture.

    The light is relative to plain white, in 4095ths, and anything brighter than white is cut off there: a picture
    of a desktop wants its white as white, and has no room for highlights above it.
    """
    light = []
    for code in range(1024):
        # The curve HDR screens are sent in (SMPTE ST 2084), which gives nits out of 10000.
        power = (code / 1023) ** (4096 / (2523 * 128))
        nits = 10000 * (max(power - 3424 / 4096, 0) / (2413 / 128 - 2392 / 128 * power)) ** (16384 / 2610)
        light.append(round(min(nits / white, 1.0) * 4095))
    # A sum arrives with 4096 added, which kept it from going below nothing on the way.
    plain = bytes(screen_curve((mixed - 4096) / 4095) for mixed in range(16384))
    return tuple(light), plain


def float_table(white):
    """For each 16 bit float an HDR screen can send, the 8 bit value of a plain picture. 1.0 there is 80 nits."""
    values = struct.unpack("<65536e", struct.pack("<65536H", *range(65536)))
    return bytes(0 if math.isnan(value) else screen_curve(value * 80 / white) for value in values)


def lanes(values, width, mask):
    """One value a pixel out of a whole row held as one number, 32 bits to each pixel."""
    return memoryview((values & mask).to_bytes(width * 4, "little")).cast("I")


def hdr_rows(data, width, height, pitch, white):
    """Rows of 8 bit RGB from 10 bit HDR. A row is worked on as one large number, which is what makes this fast
    enough without a library: adding and shifting it does every pixel at once."""
    light, plain = hdr_tables(white)
    ten = int.from_bytes(b"\xff\x03\0\0" * width, "little")
    fourteen = int.from_bytes(b"\xff\x3f\0\0" * width, "little")
    # Added to every pixel before the parts with a minus are taken off, so that none of them borrows from its neighbour.
    floor = int.from_bytes((1 << 22).to_bytes(4, "little") * width, "little")
    for y in range(height):
        word = int.from_bytes(data[y * pitch:y * pitch + width * 4], "little")
        lit = []
        for colour in range(3):
            codes = lanes(word >> (10 * colour), width, ten)
            lit.append(int.from_bytes(memoryview(array.array("I", map(light.__getitem__, codes))).cast("B"), "little"))
        out = bytearray(width * 3)
        for colour, parts in enumerate(WIDE_TO_PLAIN):
            mixed = floor + sum(part * lit[n] for n, part in enumerate(parts) if part > 0)
            mixed -= sum(-part * lit[n] for n, part in enumerate(parts) if part < 0)
            out[colour::3] = bytes(map(plain.__getitem__, lanes(mixed >> 10, width, fourteen)))
        yield bytes(out)


def float_rows(data, width, height, pitch, white):
    """Rows of 8 bit RGB from HDR sent as 16 bit floats, whose colours are already those of a plain picture."""
    plain = float_table(white)
    for y in range(height):
        row = memoryview(data[y * pitch:y * pitch + width * 8]).cast("H")
        out = bytearray(width * 3)
        for colour in range(3):
            out[colour::3] = bytes(map(plain.__getitem__, row[colour::4]))
        yield bytes(out)


def rgb_rows(kind, data, width, height, pitch):
    """Rows of 8 bit RGB from a frame in one of Looking Glass's plain formats."""
    size, order = PIXEL[kind], (2, 1, 0) if kind in (BGRA, BGR_32) else (0, 1, 2)
    lanes = int.from_bytes(b"\xff\0\0\0" * width, "little")
    for y in range(height):
        row = data[y * pitch:y * pitch + width * size]
        out = bytearray(width * 3)
        if kind == RGBA10:
            # Ten bits a colour in one word a pixel. The top eight of each, all pixels of the row in one sum.
            word = int.from_bytes(row, "little")
            for colour in range(3):
                out[colour::3] = ((word >> (2 + 10 * colour)) & lanes).to_bytes(width * 4, "little")[0::4]
        else:
            for colour in range(3):
                out[colour::3] = row[order[colour]::size]
        yield bytes(out)


def shared_by_looking_glass(path):
    memory = shared_frames(path)
    queues = frame_queues(memory)
    # The host program writes over its oldest frame as it goes, so a copy counts only when nothing changed under it.
    for _ in range(50):
        found = newest_frame(memory, queues)
        if found:
            fields, start, pixels = found
            _, _, kind, _, _, _, rows, width, height, rotation, _, pitch, _, flags, _, white = fields
            data = memory[pixels + 4:pixels + 4 + rows * pitch]
            written = struct.unpack_from("<I", memory, pixels)[0]
            if FRAME.unpack_from(memory, start) == fields and written >= rows * pitch and height <= rows:
                if flags & TRUNCATED:
                    print("guest-shot: the frame is cut short, the memory Looking Glass shares is too small for this screen", file=sys.stderr)
                if rotation:
                    print(f"guest-shot: the guest's screen is turned by {rotation * 90} degrees, the picture is as it is sent", file=sys.stderr)
                if pitch * height > len(data) or width * PIXEL[kind] > pitch:
                    fail("the newest frame does not hold the rows it says it has")
                # The driver says how bright plain white is. 80 nits is what it means when it says nothing.
                white = white if 40 <= white <= 10000 else 80
                if kind == RGBA16F:
                    rows = float_rows(data, width, height, pitch, white)
                elif kind == RGBA10 and flags & HDR_PQ:
                    rows = hdr_rows(data, width, height, pitch, white)
                else:
                    rows = rgb_rows(kind, data, width, height, pitch)
                return width, height, rows, None
        time.sleep(0.01)
    fail("Looking Glass has no finished frame to give, try again")


def of_window(args):
    """One window of a Windows guest, drawn there by the helper on the desktop and brought over as plain rows."""
    guest = Guest()
    if not guest.windows():
        fail("only a Windows guest draws one of its windows on request")
    exe, path = programs.helper(), f"C:\\Windows\\Temp\\vm-inspect-{secrets.token_hex(8)}.raw"
    which = ["--handle", str(int(args.window, 16))] if re.fullmatch(r"0x[0-9a-fA-F]+", args.window) else ["--title", args.window]
    asked = [exe, "shot", *which, "--out", path] + (["--crop", ",".join(map(str, args.crop))] if args.crop else [])
    code, out, err, _ = programs.helped(guest, lambda: guest.run([exe, "run", "--desktop", "--grant", exe, exe, subprocess.list2cmdline(asked)]))
    try:
        if code != 0:
            fail(plain(err).strip()[:300] or "the guest did not draw the window")
        data, more = guest.read(path, 0, WINDOW)
    finally:
        try:
            guest.run(["cmd.exe", "/d", "/c", "del", "/f", "/q", path])
        except (Refused, SystemExit):
            pass
    mark, width, height = RAW.unpack_from(data) if len(data) >= RAW.size else (b"", 0, 0)
    if mark != b"VMSHOT\0\0" or more or not (0 < width <= 16384 and 0 < height <= 16384) or len(data) != RAW.size + width * height * 3:
        fail("what the guest sent as the window's picture is not one")
    print(f"guest-shot: the guest drew its window {plain(out).strip()[:200]}", file=sys.stderr)

    def rows():
        for y in range(height):
            row, out = data[RAW.size + y * width * 3:RAW.size + (y + 1) * width * 3], bytearray(width * 3)
            for colour in range(3):
                out[colour::3] = row[2 - colour::3]
            yield bytes(out)

    return width, height, rows(), None


def cut(width, height, rows, box):
    """The part of a picture inside a box, which is narrowed to what the picture has."""
    left, top, wide, high = box
    if rows is None:
        fail("this picture came in a format that cannot be cut")
    if min(box) < 0 or not wide or not high or left >= width or top >= height:
        fail(f"that part lies outside the picture, which is {width}x{height}")
    wide, high = min(wide, width - left), min(high, height - top)
    return wide, high, (row[left * 3:(left + wide) * 3] for row in itertools.islice(rows, top, top + high)), None


def shot(args):
    frames = os.path.join(session_folder(), "frames.sock")
    picture = None
    if args.window:
        picture = of_window(args)
    elif args.source != "frames":
        try:
            picture = drawn_by_qemu()
        except Refused as e:
            if args.source == "qemu" or not os.path.exists(frames):
                fail(f"{e}, and the guest shares no frames through Looking Glass" if args.source == "auto" else str(e))
    elif not os.path.exists(frames):
        fail("this guest shares no frames through Looking Glass")
    width, height, rows, ready = picture or shared_by_looking_glass(frames)
    # A window is cut where it is drawn, which saves bringing the rest over.
    if args.crop and not args.window:
        width, height, rows, ready = cut(width, height, rows, args.crop)
    path = args.file or time.strftime("guest-shot-%Y%m%d-%H%M%S.png")
    with open(path, "wb") as f:
        f.write(ready or png(width, height, rows))
    print(f"{path} {width}x{height}")

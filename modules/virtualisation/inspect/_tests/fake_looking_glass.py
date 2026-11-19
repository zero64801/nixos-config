"""Writes what a Looking Glass host leaves in its shared memory: one queue, one finished frame of a known pattern."""
import mmap
import os
import struct
import sys
import time
import zlib

WHITE = 240


def light(value):
    """The light an 8 bit value of a plain picture stands for, from 0 to 1."""
    value /= 255
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def hdr_word(red, green, blue):
    """A pixel as an HDR screen is sent it: wide colours, the HDR curve, ten bits each."""
    plain = [light(red), light(green), light(blue)]
    wide = ((0.6274, 0.3293, 0.0433), (0.0691, 0.9195, 0.0114), (0.0164, 0.0880, 0.8956))
    word = 3 << 30
    for n, row in enumerate(wide):
        nits = sum(part * value for part, value in zip(row, plain)) * WHITE
        power = (nits / 10000) ** (2610 / 16384)
        code = ((3424 / 4096 + 2413 / 128 * power) / (1 + 2392 / 128 * power)) ** (2523 * 128 / 4096)
        word |= round(code * 1023) << (10 * n)
    return word


def build(memory, width, height, kind=1, serial=7, subscribed=True, pitch=None, hdr=False):
    # Type 5 is 24 bit pixels packed into a 32 bit surface, so its data is narrower than its frame.
    size = {1: 4, 2: 4, 3: 4, 4: 8, 5: 3, 6: 3}[kind]
    pitch = pitch or width * size + 8
    packed = pitch // 4 if kind == 5 else width
    queue = 64
    struct.pack_into("<I", memory, queue + 192, (1 << 16) if subscribed else 0)
    struct.pack_into("<3I", memory, queue + 296, 2, 2, 16384)
    struct.pack_into("<5I", memory, 9664, 0x504d474c, 12, 99, 1, 48)
    memory[9684:9692] = b"KVMFR---"
    struct.pack_into("<I", memory, 9692, 34)
    frame = 1 << 20
    struct.pack_into("<QII", memory, 16384, 0, 0, frame)
    struct.pack_into("<16I", memory, frame, 1, serial, kind, width, height, packed, height, width, height, 0, packed, pitch, 4092,
                     0x18 if hdr else 0, 0, WHITE)
    for y in range(height):
        row = bytearray(pitch)
        for x in range(width):
            red, green, blue = (x ^ y) & 255, y & 255, x & 255
            if kind == 5:
                row[x * 3:x * 3 + 3] = bytes((blue, green, red))
            elif kind == 1:
                row[x * 4:x * 4 + 4] = bytes((blue, green, red, 255))
            elif kind == 2:
                row[x * 4:x * 4 + 4] = bytes((red, green, blue, 255))
            elif kind == 6:
                row[x * 3:x * 3 + 3] = bytes((red, green, blue))
            elif kind == 4:
                # Floats count light in units of 80 nits.
                row[x * 8:x * 8 + 8] = struct.pack("<4e", *(light(c) * WHITE / 80 for c in (red, green, blue)), 1.0)
            elif hdr:
                row[x * 4:x * 4 + 4] = struct.pack("<I", hdr_word(red, green, blue))
            else:
                row[x * 4:x * 4 + 4] = struct.pack("<I", red << 2 | green << 12 | blue << 22 | 3 << 30)
        memory[frame + 4096 + y * pitch:frame + 4096 + (y + 1) * pitch] = row
    struct.pack_into("<I", memory, frame + 4092, height * pitch)


def check(path, width, height, slack=0):
    """Fails unless the PNG at the path shows the pattern at the size given, each value within the slack."""
    with open(path, "rb") as f:
        picture = f.read()
    place, packed, size = 8, b"", None
    while place < len(picture):
        length, kind = struct.unpack(">I4s", picture[place:place + 8])
        body = picture[place + 8:place + 8 + length]
        if kind == b"IHDR":
            size = struct.unpack(">II", body[:8])
        if kind == b"IDAT":
            packed += body
        place += 12 + length
    if size != (width, height):
        sys.exit(f"the picture is {size}, not {(width, height)}")
    raw = zlib.decompress(packed)
    for y in range(height):
        row = raw[y * (width * 3 + 1) + 1:(y + 1) * (width * 3 + 1)]
        for x in range(width):
            wanted = ((x ^ y) & 255, y & 255, x & 255)
            if any(abs(got - want) > slack for got, want in zip(row[x * 3:x * 3 + 3], wanted)):
                sys.exit(f"the pixel at {x},{y} is {tuple(row[x * 3:x * 3 + 3])}, not {wanted}")
    print("the picture shows the pattern")


if __name__ == "__main__":
    if sys.argv[1] == "check":
        check(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]) if sys.argv[5:] else 0)
        sys.exit(0)
    # The device is no file to seek in, and tells its size to no one who asks the usual way.
    memory = mmap.mmap(os.open(sys.argv[1], os.O_RDWR), int(sys.argv[5]))
    build(memory, int(sys.argv[2]), int(sys.argv[3]), kind=int(sys.argv[6]) if sys.argv[6:] else 1, subscribed=sys.argv[4:5] != ["unwatched"],
          hdr=sys.argv[7:8] == ["hdr"])
    beat = 1
    # The heartbeat a running host program keeps up.
    while sys.argv[4:5] != ["stopped"]:
        struct.pack_into("<Q", memory, 0, beat)
        beat += 1
        time.sleep(0.05)

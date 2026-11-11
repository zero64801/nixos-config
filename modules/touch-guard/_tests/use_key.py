"""Opens the fake key and, by mode, holds it idle, asks through write, or asks through the output report ioctl."""
import fcntl
import glob
import os
import sys
import time


def node():
    for path in glob.glob("/sys/class/hidraw/hidraw*"):
        with open(os.path.join(path, "device", "uevent")) as f:
            if "Fake Security Key" in f.read():
                return "/dev/" + os.path.basename(path)
    sys.exit("no fake key")


mode = sys.argv[1]
fd = os.open(node(), os.O_RDWR)
request = bytes([0, 0, 0, 0, 7, 0x90, 0, 1, 4]).ljust(65, b"\0")
if mode == "write":
    os.write(fd, request)
elif mode == "ioctl":
    # HIDIOCSOUTPUT(len): _IOC(_IOC_WRITE | _IOC_READ, 'H', 0x0B, len)
    fcntl.ioctl(fd, (3 << 30) | (len(request) << 16) | (ord("H") << 8) | 0x0B, request)
time.sleep(float(sys.argv[2]) if len(sys.argv) > 2 else 6)

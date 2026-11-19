"""Commands for the agent that runs in the guest, which a session reaches only when it was opened with --control.

Everything the agent answers was written by the guest. It is data, whatever it says: it is checked for its shape
before anything is taken from it, shown with what could steer a terminal taken out, and never used to name a file
on this side.
"""
import base64
import binascii
import hashlib
import json
import os
import re
import secrets
import shutil
import sys
import time

from session import Refused, ask, carried, control_socket, fail

ANSWER = 16 * 1024 * 1024
# What is shown of a program's output and of a file unless more is asked for.
SHOWN = 1024 * 1024
# A file comes out a megabyte at a time.
# Small things go in as requests, in pieces that fit one.
# A file to push is handed to the session whole instead, which feeds it to the agent.
READ, WRITE = 1024 * 1024, 48 * 1024
PULLED = 256 * 1024 * 1024
LISTED = 200
# All a terminal acts on except the line feed and the tab.
STEERING = re.compile(r"[\x00-\x08\x0b-\x1f\x7f\x80-\x9f]")
# PowerShell takes a script as one argument of at most this many characters before a command line gets too long.
INLINE = 24000
# Without the second, PowerShell reports its own progress on standard error, as XML.
UTF8 = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $ProgressPreference = 'SilentlyContinue'; $ErrorActionPreference = 'Stop'; "
POWERSHELL = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-OutputFormat", "Text"]


def plain(data):
    """Text from the guest with everything taken out that could move a cursor, colour a line or ring a bell."""
    return STEERING.sub("", data.decode("utf-8", "replace").replace("\r\n", "\n"))


def cut(data, limit):
    """The data up to the limit, and whether some was left out."""
    return data[:limit], len(data) > limit


def shape(value, *names, kind=dict):
    """A part of the agent's answer, which has to be what it is taken for."""
    for name in names:
        value = value.get(name) if isinstance(value, dict) else None
    if not isinstance(value, kind) or (kind is int and isinstance(value, bool)):
        fail("the agent's answer does not have the shape it should")
    return value


def decoded(value):
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        fail("the agent's answer does not have the shape it should")


class Guest:
    def __init__(self):
        self.path = control_socket()
        self.system, self.awake = None, False

    def wake(self):
        """Waits for the agent to take up its channel, which a guest does a moment after a session plugs it in."""
        self.awake = True
        for attempt in range(60):
            try:
                self.ask("ping")
                return
            except Refused as e:
                if "not connected" not in str(e) and "not responding" not in str(e) or attempt == 59:
                    raise
            time.sleep(0.25)

    def ask(self, name, **arguments):
        """What the agent returns for one command."""
        if not self.awake:
            self.wake()
        request = {"do": "agent", "execute": f"guest-{name}", "arguments": {k.replace("_", "-"): v for k, v in arguments.items()}}
        try:
            answer = json.loads(carried(*ask(self.path, request), ANSWER))
        except (ValueError, RecursionError):
            fail("the agent's answer is not JSON")
        if not isinstance(answer, dict) or "return" not in answer:
            fail("the agent's answer does not have the shape it should")
        return answer["return"]

    def windows(self):
        if self.system is None:
            told = self.ask("get-osinfo")
            self.system = str(told.get("id")) if isinstance(told, dict) else ""
        return self.system == "mswindows"

    def run(self, command, given=None, timeout=60, stopped=True):
        """Runs a program in the guest and waits for it: its exit code, what it printed and what it complained of."""
        arguments = {"path": command[0], "arg": list(command[1:]), "capture_output": True}
        if given is not None:
            arguments["input_data"] = base64.b64encode(given).decode()
        pid = shape(self.ask("exec", **arguments), "pid", kind=int)
        ends, pause = time.monotonic() + timeout, 0.05
        while True:
            status = self.status(pid)
            if status is not None:
                break
            if time.monotonic() > ends:
                if stopped:
                    self.stop(pid)
                fail(f"the program was still running after {timeout} seconds" + (" and has been stopped" if stopped else ""))
            time.sleep(pause)
            pause = min(pause * 1.5, 1.0)
        code = status.get("exitcode", status.get("signal", 1))
        return (code if isinstance(code, int) else 1,
                decoded(status.get("out-data", "")), decoded(status.get("err-data", "")),
                bool(status.get("out-truncated") or status.get("err-truncated")))

    def status(self, pid):
        """How a program this started ended, or None while it runs.

        The agent finds a program by its number and answers for the first it keeps under it, which can be an earlier program that
        the guest gave the same number and that nobody asked about. An answer that a program ended is taken once no other is kept.
        """
        told = shape(self.ask("exec-status", pid=pid))
        for _ in range(KEPT):
            if not shape(told, "exited", kind=bool):
                return None
            try:
                again = shape(self.ask("exec-status", pid=pid))
            except Refused:
                return told
            told = again
        fail(f"the agent keeps answering that program {pid} ended")

    def stop(self, pid):
        """Ends a program this started and takes what the agent keeps of it."""
        command = ["taskkill.exe", "/pid", str(pid), "/t", "/f"] if self.windows() else ["/bin/sh", "-c", f"kill -9 {pid}"]
        # A stop is the last thing done for a program, so its own trouble must not hide why the program was stopped.
        try:
            self.run(command, timeout=10, stopped=False)
            self.forget(pid)
        except (Refused, SystemExit):
            pass

    def forget(self, pid):
        """Asks how an ended program ended, which is when the agent lets go of it.

        The agent finds a program by its number and takes the first it knows under it, so one it still keeps would answer for a
        later program that the guest gave the same number.
        """
        for _ in range(100):
            try:
                if self.status(pid) is not None:
                    return
            except Refused:
                return
            time.sleep(0.05)

    def powershell(self, script, *values, timeout=60):
        """Runs a PowerShell script in a Windows guest. Its values go in as data, so nothing in them is read as script."""
        # The values sit in an object, since a list on its own comes out of ConvertFrom-Json as one thing.
        # An error is caught and said in plain words, since PowerShell would write it to standard error as XML.
        packed = base64.b64encode(json.dumps({"v": values}).encode()).decode()
        script = (f"{UTF8}try {{ $a = (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{packed}')))).v; "
                  f"{script} }} catch {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}")
        encoded = base64.b64encode(script.encode("utf-16-le")).decode()
        if len(encoded) <= INLINE:
            return self.run([*POWERSHELL, "-EncodedCommand", encoded], timeout=timeout)
        # Too long for a command line, so it goes in as a file that is taken away again.
        path = f"C:\\Windows\\Temp\\vm-inspect-{secrets.token_hex(8)}.ps1"
        self.write(path, b"\xef\xbb\xbf" + script.encode())
        try:
            return self.run([*POWERSHELL, "-File", path], timeout=timeout)
        finally:
            self.run(["cmd.exe", "/c", "del", "/f", "/q", path])

    def script(self, windows, posix, *values, timeout=60):
        """Runs the one of two scripts that fits the guest: PowerShell for Windows, a shell's for the rest."""
        if self.windows():
            return self.powershell(windows, *values, timeout=timeout)
        return self.run(["/bin/sh", "-c", posix, "sh", *[str(value) for value in values]], timeout=timeout)

    def read(self, path, start=0, limit=SHOWN):
        """A file's bytes from a place on, up to a limit, and whether the file went on after it."""
        handle = shape(self.ask("file-open", path=path, mode="r"), kind=int)
        try:
            if start:
                self.ask("file-seek", handle=handle, offset=start, whence=0)
            data, ended = b"", False
            while len(data) <= limit and not ended:
                piece = shape(self.ask("file-read", handle=handle, count=min(READ, limit + 1 - len(data))))
                data += decoded(shape(piece, "buf-b64", kind=str))
                ended = shape(piece, "eof", kind=bool)
            return data[:limit], len(data) > limit or not ended
        finally:
            self.ask("file-close", handle=handle)

    def exists(self, path):
        try:
            handle = shape(self.ask("file-open", path=path, mode="r"), kind=int)
        except Refused:
            return False
        self.ask("file-close", handle=handle)
        return True

    def size(self, path):
        handle = shape(self.ask("file-open", path=path, mode="r"), kind=int)
        try:
            return shape(self.ask("file-seek", handle=handle, offset=0, whence=2), "position", kind=int)
        finally:
            self.ask("file-close", handle=handle)

    def write(self, path, data, told=None):
        handle = shape(self.ask("file-open", path=path, mode="w"), kind=int)
        try:
            for start in range(0, len(data), WRITE):
                self.ask("file-write", handle=handle, buf_b64=base64.b64encode(data[start:start + WRITE]).decode())
                if told:
                    told(min(start + WRITE, len(data)), len(data))
        finally:
            self.ask("file-close", handle=handle)

    def sha256(self, path):
        code, out, err, _ = self.script("(Get-FileHash -LiteralPath $a[0] -Algorithm SHA256).Hash.ToLower()",
                                        'sha256sum -- "$1" | cut -d" " -f1', path, timeout=600)
        found = plain(out).strip()
        if code != 0 or not re.fullmatch(r"[0-9a-f]{64}", found):
            fail(f"the guest could not hash {path}: {plain(err).strip()[:300]}")
        return found


def show(tool, code, out, err, limit, cut_short=False):
    """Prints what a program in the guest said, marked as the guest's words, and ends with a status that tells how it went."""
    out, more_out = cut(out, limit)
    err, more_err = cut(err, limit)
    print(f"guest-{tool}: exit {code}, what follows was written by the guest", file=sys.stderr)
    sys.stdout.write(plain(out))
    sys.stdout.flush()
    sys.stderr.write(plain(err))
    if more_out or more_err or cut_short:
        print(f"\nguest-{tool}: more than {limit} bytes, the rest is left out", file=sys.stderr)
    sys.exit(0 if code == 0 else (code & 0xff) or 1)


def read(args):
    guest = Guest()
    start = args.offset
    if args.tail is not None:
        start = max(guest.size(args.path) - args.max, 0)
    data, more = guest.read(args.path, start, args.max)
    if args.raw:
        sys.stdout.buffer.write(data)
        return
    text = plain(data)
    if args.head is not None:
        text = "".join(text.splitlines(keepends=True)[:args.head])
    if args.tail is not None:
        text = "".join(text.splitlines(keepends=True)[-args.tail:])
    print(f"guest-read: {len(data)} bytes from {start} on, written by the guest", file=sys.stderr)
    sys.stdout.write(text)
    if more and args.head is None and args.tail is None:
        print(f"\nguest-read: the file goes on, this is {args.max} bytes of it", file=sys.stderr)


def progress(done, total):
    if sys.stderr.isatty():
        print(f"\r{done * 100 // max(total, 1)}% of {total} bytes", end="", file=sys.stderr)


# From this size on a file travels as a disk of its own, which is far faster and takes about two seconds to set up.
# Measured on a Windows guest, where the agent moves 40 to 65 MB a second, the disk is ahead from about 120 MB on.
BY_DISK = 128 * 1024 * 1024
# More ended programs under one number than an agent keeps for real, which only a guest that lies about it gets to.
KEPT = 64
# What reads and writes a disk as plain bytes in a Windows guest.
# PowerShell cannot open a disk by itself, so a small class does it, with every read and write a whole number of sectors as a disk wants them.
RAW_DISK = r'''Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class VmInspectDisk {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
  static FileStream Open(int number, bool write) {
    SafeFileHandle handle = CreateFile("\\\\.\\PhysicalDrive" + number, write ? 0xC0000000u : 0x80000000u, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (handle.IsInvalid) throw new IOException("the disk cannot be opened, error " + Marshal.GetLastWin32Error());
    return new FileStream(handle, write ? FileAccess.ReadWrite : FileAccess.Read, 1);
  }
  public static void ToFile(int number, string path, long count) {
    byte[] buffer = new byte[4 << 20];
    using (FileStream disk = Open(number, false)) using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20)) {
      while (count > 0) {
        int want = (int)Math.Min(buffer.Length, (count + 511) / 512 * 512), got = 0;
        while (got < want) { int n = disk.Read(buffer, got, want - got); if (n <= 0) throw new IOException("the disk ended early"); got += n; }
        int keep = (int)Math.Min(got, count);
        file.Write(buffer, 0, keep); count -= keep;
      }
    }
  }
  public static void FromFile(int number, string path, long count) {
    byte[] buffer = new byte[4 << 20];
    using (FileStream disk = Open(number, true)) using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20)) {
      while (count > 0) {
        int want = (int)Math.Min(buffer.Length, count), got = 0;
        while (got < want) { int n = file.Read(buffer, got, want - got); if (n <= 0) throw new IOException("the file ended early"); got += n; }
        int whole = (got + 511) / 512 * 512;
        Array.Clear(buffer, got, whole - got);
        disk.Write(buffer, 0, whole); count -= got;
      }
      disk.Flush();
    }
  }
}
'@
$disk = $null
for ($i = 0; $i -lt 100 -and -not $disk; $i++) {
  $disk = Get-Disk | Where-Object { $_.SerialNumber -and $_.SerialNumber.Trim() -eq 'vm-inspect-data' }
  if (-not $disk) { Start-Sleep -Milliseconds 200 }
}
if (-not $disk) { throw 'the disk for the transfer did not appear' }
'''
FROM_DISK = RAW_DISK + "[VmInspectDisk]::ToFile($disk.Number, $a[0], $a[1])"
TO_DISK = RAW_DISK + ("if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }; "
                      "if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }; "
                      "[VmInspectDisk]::FromFile($disk.Number, $a[0], $a[1])")
# The same for a guest with a shell: the disk is the one whose serial number is the transfer's.
FIND_DISK = '''dev=; n=0
while [ -z "$dev" ] && [ "$n" -lt 100 ]; do
  for d in /sys/block/sd* /sys/block/vd*; do
    if grep -qs vm-inspect-data "$d/device/vpd_pg80" "$d/serial"; then dev=/dev/${d##*/}; fi
  done
  [ -n "$dev" ] || { sleep 0.2; n=$((n + 1)); }
done
[ -n "$dev" ] || { echo "the disk for the transfer did not appear" >&2; exit 1; }
'''
FROM_DISK_SH = FIND_DISK + 'head -c "$2" "$dev" > "$1"'
TO_DISK_SH = FIND_DISK + 'dd if="$1" of="$dev" bs=4M conv=fsync 2>/dev/null'


def by_disk(guest, file, write, windows, posix, path, size):
    """Moves a file's bytes over a disk that is the guest's for just this long. Says why it could not, or None."""
    try:
        ask(guest.path, {"do": "disk", "write": write}, carrying=[file.fileno()])
    except Refused as e:
        return str(e)
    try:
        code, _, err, _ = guest.script(windows, posix, path, size, timeout=180 + size // 5000000)
        return None if code == 0 else plain(err).strip()[:300] or "the guest could not copy to or from the disk"
    finally:
        ask(guest.path, {"do": "undisk"})


def pace(size, moved, started):
    """How a transfer went: its speed when it is large enough to have one, then the whole time with both checks."""
    speed = f" at {size / max(moved, 0.001) / 1e6:.0f} MB a second" if size >= 1000000 else ""
    return f"{speed}, {time.monotonic() - started:.1f} seconds in all"


def push(args):
    guest = Guest()
    started = time.monotonic()
    with open(args.file, "rb") as f:
        size = os.fstat(f.fileno()).st_size
        mine = hashlib.file_digest(f, "sha256").hexdigest()
        f.seek(0)
        way = "disk" if (args.disk or size >= BY_DISK) and not args.stream and size else "agent"
        begun = time.monotonic()
        if way == "disk":
            why = by_disk(guest, f, False, FROM_DISK, FROM_DISK_SH, args.path, size)
            if why:
                print(f"guest-push: not by disk ({why}), so through the agent", file=sys.stderr)
                way, begun = "agent", time.monotonic()
        if way == "agent":
            handle = shape(guest.ask("file-open", path=args.path, mode="w"), kind=int)
            try:
                # The session feeds the file to the agent itself, which takes as long as the file is large.
                ask(guest.path, {"do": "push", "handle": handle, "size": size}, carrying=[f.fileno()], patience=120 + size // 500000)
            finally:
                guest.ask("file-close", handle=handle)
        moved = time.monotonic() - begun
    if guest.sha256(args.path) != mine:
        fail(f"{args.path} did not arrive as it was sent")
    print(f"{size} bytes are in the guest as {args.path}, checked. By {way}{pace(size, moved, started)}")


def pull(args):
    guest = Guest()
    started = time.monotonic()
    # The name on this side is taken from what was asked for, never from what the guest says, and only its plain part.
    name = re.sub(r"[^A-Za-z0-9._-]", "_", re.split(r"[\\/]", args.path)[-1]) or "pulled"
    target = args.file or os.path.join("out" if os.path.isdir("out") else ".", name)
    size = guest.size(args.path)
    if size > args.max:
        fail(f"{args.path} is {size} bytes, more than the {args.max} allowed. Raise it with --max")
    if shutil.disk_usage(os.path.dirname(os.path.abspath(target))).free < size + 64 * 1024 * 1024:
        fail("there is not enough room here for it")
    way = "disk" if (args.disk or size >= BY_DISK) and not args.stream and size else "agent"
    begun = time.monotonic()
    if way == "disk":
        with open(target, "w+b") as f:
            # A disk is whole sectors. What is beyond the file's own size is cut off again once the guest has written.
            f.truncate((size + 511) // 512 * 512)
            why = by_disk(guest, f, True, TO_DISK, TO_DISK_SH, args.path, size)
            moved = time.monotonic() - begun
            f.truncate(size)
            f.seek(0)
            got, mine = size, hashlib.file_digest(f, "sha256").hexdigest()
        if why:
            print(f"guest-pull: not by disk ({why}), so through the agent", file=sys.stderr)
            way, begun = "agent", time.monotonic()
    if way == "agent":
        got, mine = through_agent(guest, args.path, target, size, args.max)
        moved = time.monotonic() - begun
    if guest.sha256(args.path) != mine:
        fail(f"{target} is not what the guest says the file is, it may have changed while it was read")
    print(f"{got} bytes of {args.path} are in {target}, checked. By {way}{pace(got, moved, started)}. The file is the guest's: read it, do not run it")


def through_agent(guest, path, target, size, limit):
    """Reads a file of the guest piece by piece through its agent into one here. The bytes read and their SHA-256."""
    handle = shape(guest.ask("file-open", path=path, mode="r"), kind=int)
    digest, got = hashlib.sha256(), 0
    try:
        with open(target, "wb") as f:
            while True:
                piece = shape(guest.ask("file-read", handle=handle, count=READ))
                data = decoded(shape(piece, "buf-b64", kind=str))
                got += len(data)
                if got > limit:
                    fail("the file grew past what is allowed while it was read")
                f.write(data)
                digest.update(data)
                progress(got, size)
                if shape(piece, "eof", kind=bool) or not data:
                    break
    finally:
        guest.ask("file-close", handle=handle)
    if sys.stderr.isatty():
        print(file=sys.stderr)
    return got, digest.hexdigest()


def listing(args):
    guest = Guest()
    code, out, err, _ = guest.script(
        "Get-ChildItem -LiteralPath $a[0] -Force | Select-Object -First $a[1] | ForEach-Object { "
        "'{0}  {1,14}  {2:yyyy-MM-dd HH:mm}  {3}' -f $_.Mode, $(if ($_.PSIsContainer) { '' } else { $_.Length }), $_.LastWriteTime, $_.Name }",
        'ls -la -- "$1" | head -n "$2"', args.path, args.max)
    show("ls", code, out, err, SHOWN)


def details(args):
    guest = Guest()
    code, out, err, _ = guest.script(
        "(Get-Item -LiteralPath $a[0] -Force | Format-List FullName, Mode, Length, CreationTime, LastWriteTime, Attributes | Out-String -Width 300).Trim()",
        'stat -- "$1"', args.path)
    show("stat", code, out, err, SHOWN)


def digest(args):
    print(Guest().sha256(args.path))


def search(args):
    guest = Guest()
    code, out, err, _ = guest.script(
        "$found = if (Test-Path -LiteralPath $a[1] -PathType Container) { Get-ChildItem -LiteralPath $a[1] -Recurse -File -Force -ErrorAction SilentlyContinue } "
        "else { Get-Item -LiteralPath $a[1] -Force }; "
        "$found | Select-String -Pattern $a[0] -SimpleMatch:$a[2] -CaseSensitive:(-not $a[3]) -Context $a[4] -ErrorAction SilentlyContinue | "
        "Select-Object -First $a[5] | ForEach-Object { "
        "foreach ($l in $_.Context.PreContext) { '{0}-{1}' -f $_.Path, $l }; '{0}:{1}:{2}' -f $_.Path, $_.LineNumber, $_.Line; "
        "foreach ($l in $_.Context.PostContext) { '{0}-{1}' -f $_.Path, $l } }",
        'grep -rn $( [ "$3" = True ] && echo -F ) $( [ "$4" = True ] && echo -i ) -C "$5" -e "$1" -- "$2" | head -n "$6"',
        args.pattern, args.path, args.fixed, args.ignore_case, args.context, args.max, timeout=args.timeout)
    # A search that finds nothing ends with 1 where a shell runs it, which is no failure.
    show("grep", 0 if code == 1 and not err.strip() else code, out, err, SHOWN)


def find(args):
    guest = Guest()
    code, out, err, _ = guest.script(
        "Get-ChildItem -LiteralPath $a[0] -Recurse -Force -Filter $a[1] -ErrorAction SilentlyContinue | Select-Object -First $a[2] | ForEach-Object { $_.FullName }",
        'find "$1" -name "$2" 2>/dev/null | head -n "$3"', args.path, args.name, args.max, timeout=args.timeout)
    show("find", code, out, err, SHOWN)


def system_told(guest):
    system = shape(guest.ask("get-osinfo"))
    name, release = system.get("pretty-name") or system.get("name"), system.get("kernel-release") or system.get("kernel-version")
    return f"{name} {system.get('version') or ''} ({release}, {system.get('machine')})"


def disks_told(guest):
    disks = []
    for disk in shape(guest.ask("get-fsinfo"), kind=list):
        if isinstance(disk, dict) and isinstance(disk.get("total-bytes"), int) and isinstance(disk.get("used-bytes"), int):
            free = (disk["total-bytes"] - disk["used-bytes"]) / 2 ** 30
            disks.append(f"{disk.get('mountpoint')} {free:.1f} of {disk['total-bytes'] / 2 ** 30:.1f} GiB free")
    return "; ".join(disks) or "none told"


def status(args):
    guest = Guest()
    asked = {
        "agent": lambda: shape(guest.ask("info"), "version", kind=str),
        "system": lambda: system_told(guest),
        "name": lambda: shape(guest.ask("get-host-name"), "host-name", kind=str),
        "users": lambda: ", ".join(str(user.get("user")) for user in shape(guest.ask("get-users"), kind=list) if isinstance(user, dict)) or "none logged in",
        "clock": lambda: f"{shape(guest.ask('get-time'), kind=int) / 1e9 - time.time():+.1f} seconds from this side's",
        "disks": lambda: disks_told(guest),
    }
    told = {}
    for name, find_out in asked.items():
        # An agent may lack one of these, which is no reason to say nothing of the rest.
        try:
            told[name] = find_out()
        except Refused as e:
            told[name] = f"not told ({e})"
    if args.json:
        json.dump({name: plain(str(value).encode()) for name, value in told.items()}, sys.stdout)
        print()
        return
    print("guest-status: what follows was written by the guest", file=sys.stderr)
    for name, value in told.items():
        print(f"{name}: {plain(str(value).encode())[:400]}")


def agent(args):
    """One command for the agent in the guest. Its answer is the guest's own words, printed as they came."""
    try:
        arguments = json.loads(args.arguments) if args.arguments else None
    except ValueError:
        fail("the arguments are one JSON object")
    name = args.name if args.name.startswith("guest-") else f"guest-{args.name}"
    try:
        answer = carried(*ask(control_socket(), {"do": "agent", "execute": name, "arguments": arguments}), ANSWER)
    except Refused as e:
        fail(str(e))
    print("guest-agent: the answer below was written by the guest", file=sys.stderr)
    sys.stdout.buffer.write(answer if answer.endswith(b"\n") else answer + b"\n")

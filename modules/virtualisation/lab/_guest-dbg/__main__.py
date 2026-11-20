"""guest-dbg: breakpoints and watchpoints in one process of a guest, set from outside through QEMU's debug stub.

Nothing is attached to a process in the guest and nothing is written into its memory. The CPU's debug registers stop
the whole guest at an address, and a stop in any other process than the one asked for is let go at once. A method of
.NET has its stop set once the JIT has compiled it, as dotnet.py says.
"""
import argparse
import collections
import os
import re
import signal
import struct
import sys
import time

import dotnet
import logs
import mi
from windows import Windows

ROOT = 0x000FFFFFFFFFF000
SIZES = {1: "unsigned char", 2: "unsigned short", 4: "unsigned int", 8: "unsigned long long"}
STEERING = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")
GENERAL = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip", "eflags", "cr3"]
OURS = ("hw breakpoint", "hw watchpoint", "acc watchpoint", "read watchpoint")


def fail(message):
    print(f"guest-dbg: {message}", file=sys.stderr)
    sys.exit(1)


def numeric(text):
    try:
        int(text, 0)
        return True
    except ValueError:
        return False


def place(spec, pid, guest):
    """The address a spec names: 0xADDRESS, MODULE, MODULE!SYMBOL, each with +OFFSET."""
    head, offset = spec, 0
    if "+" in spec and numeric(spec.rsplit("+", 1)[1]):
        head, offset = spec.rsplit("+", 1)[0], int(spec.rsplit("+", 1)[1], 0)
    if numeric(head):
        return int(head, 0) + offset
    module, _, symbol = head.partition("!")
    if symbol:
        return guest.address(pid, module, symbol) + offset
    return guest.module(pid, module)[1] + offset


def parse_arguments(words):
    parser = argparse.ArgumentParser(
        prog="guest-dbg", description=__doc__.split("\n\n")[1].replace("\n", " "),
        epilog="A place is 0xADDRESS, MODULE, MODULE!NAME or any of them with +OFFSET. NAME is an export, or a symbol where the module has some, "
               "and nt names the kernel. dotnet:[ASSEMBLY!]NAMESPACE.TYPE::METHOD[/PARAMETERS] is a method of .NET, which is stopped at "
               "once the JIT has compiled it, and following the JIT takes two more debug registers. "
               "A guest has four debug registers, so four places at most, a return taking one. "
               "Every stop halts the whole guest for a moment, and a place that other processes run through often slows the guest down.")
    parser.add_argument("process", help="a process name or number, cr3=ROOT for a page table root, or - for every process")
    parser.add_argument("--break", dest="breaks", action="append", default=[], metavar="PLACE", help="stop when this code runs")
    parser.add_argument("--watch", action="append", default=[], metavar="PLACE[:SIZE]", help="stop when this is written with another value, SIZE 1, 2, 4 or 8")
    parser.add_argument("--access", action="append", default=[], metavar="PLACE[:SIZE]", help="stop when this is read or written")
    parser.add_argument("--do", action="append", default=[], metavar="COMMAND", help="a gdb command at each stop, as x/8gx $rsp or set $rax = 0")
    parser.add_argument("--on-return", action="append", default=[], metavar="COMMAND",
                        help="a gdb command when the function a --break stopped in returns, which takes one debug register")
    parser.add_argument("--log", action="append", default=[], metavar="PLACE,BUFFER,LENGTH",
                        help="write a buffer of the process to ./out at each stop at the place and go on, or a preset: "
                             + ", ".join(sorted(logs.PRESETS)) + " (openssl=MODULE). See logs.py for the values")
    parser.add_argument("--out", metavar="NAME", help="with --log: the folder in ./out for the buffers, a new one by default")
    parser.add_argument("--max-bytes", type=int, default=1 << 20, help="with --log: the most of one buffer written, 1 MiB by default")
    parser.add_argument("--hits", type=int, help="stops in the process to wait for, 1 by default, and with --log buffers to write, "
                                                 "as many as come before the time runs out by default")
    parser.add_argument("--timeout", type=float, default=60, help="seconds to wait for them, 60 by default")
    parser.add_argument("--busy", type=int, default=20000, help="stops in other processes after which it gives up, 20000 by default")
    return parser.parse_args(words)


class Debugger:
    def __init__(self, gdb, guest, pid, roots):
        self.gdb, self.guest, self.pid, self.roots = gdb, guest, pid, roots
        self.running = False
        self.index = {}

    def go(self):
        self.gdb.run("-exec-continue")
        self.running = True

    def registers(self, names):
        values, _ = self.gdb.run("-data-list-register-values --skip-unavailable x " + " ".join(str(self.index[n]) for n in names if n in self.index))
        by_number = {int(v["number"]): int(v["value"], 16) for v in values.get("register-values", [])}
        return {n: by_number.get(self.index.get(n)) for n in names}

    def word(self, address):
        return int.from_bytes(self.read(address, 8), "little")

    def peek(self, address, length):
        """What read() gives, or nothing where the process has no memory."""
        try:
            return self.read(address, length)
        except mi.Failed:
            return b""

    def read(self, address, length):
        out = bytearray()
        while len(out) < length:
            size = min(length - len(out), 1 << 16)
            values, _ = self.gdb.run(f"-data-read-memory-bytes {address + len(out):#x} {size}")
            piece = bytes.fromhex(values["memory"][0]["contents"])
            if not piece:
                break
            out += piece
        return bytes(out)

    def where(self, address):
        name = self.guest.name(self.pid, address) if self.guest else None
        return f"{name} ({address:#x})" if name else f"{address:#x}"

    def commands(self, commands):
        for command in commands:
            try:
                printed = self.gdb.console(command)
            except mi.Failed as e:
                printed = f"gdb: {e}\n"
            print("    " + STEERING.sub("", printed).rstrip("\n").replace("\n", "\n    "))

    def show(self, registers):
        names = [n for n in GENERAL if registers.get(n) is not None]
        for at in range(0, len(names), 4):
            print("  " + "  ".join(f"{n:>6}={registers[n]:#018x}" for n in names[at:at + 4]))


def main():
    program, library = sys.argv[1:3]
    args = parse_arguments(sys.argv[3:])
    try:
        specs = logs.expand(args.log)
    except ValueError as e:
        fail(str(e))
    if args.hits is None:
        args.hits = 0 if specs else 1
    returns = bool(args.on_return) or any(spec.at_return for spec in specs)
    managed = [("break", spec) for spec in args.breaks if spec.startswith(dotnet.PREFIX)] + \
        [("log", spec.place) for spec in specs if spec.place.startswith(dotnet.PREFIX) or spec.place == "jit"]
    if len(managed) > 1:
        fail("one method of .NET or --log jit at a time, since following the JIT takes two of the four debug registers")
    used = len(args.breaks) + len(args.watch) + len(args.access) + len(specs) + (1 if returns else 0) + (2 if managed else 0)
    if not used:
        fail("there is nothing to stop at: give --break, --watch, --access or --log")
    if used > 4:
        fail(f"that takes {used} debug registers and a guest has four")
    if args.on_return and not args.breaks:
        fail("--on-return goes with a --break")
    target = os.environ.get("VM_INSPECT_GDB")
    if not target:
        fail("this runs in a session that has QEMU's debug stub open, as vm-lab opens it")

    places = [("break", spec, 1) for spec in args.breaks] + [("log", spec.place, 1) for spec in specs]
    by_place = {spec.place: spec for spec in specs}
    writer = None
    if specs:
        try:
            writer = logs.Writer(args.out or time.strftime("dbg-%Y%m%d-%H%M%S"))
        except (LookupError, OSError) as e:
            fail(str(e))
    for kind, specs in (("watch", args.watch), ("access", args.access)):
        for spec in specs:
            head, _, size = spec.rpartition(":") if re.search(r":\d+$", spec) else (spec, "", "8")
            if int(size) not in SIZES:
                fail(f"{spec}: a size is 1, 2, 4 or 8 bytes")
            places.append((kind, head, int(size)))

    raw = args.process == "-" or args.process.startswith("cr3=")
    if managed and raw:
        fail("a method of .NET is one process's, so name the process")
    guest = None
    if not raw or not all(numeric(spec.rsplit("+", 1)[0]) for _, spec, _ in places):
        try:
            guest = Windows(library, os.environ["VM_INSPECT_DEVICE"])
        except (LookupError, OSError, KeyError) as e:
            fail(str(e))
    pid, roots = None, None
    try:
        if args.process.startswith("cr3="):
            roots = {int(args.process[4:], 0) & ROOT}
            label = f"page table root {args.process[4:]}"
        elif args.process != "-":
            pid = guest.pid(args.process)
            name, found = guest.process(pid)
            roots = {r & ROOT for r in found}
            label = f"{name}, process {pid}"
        else:
            label = "every process"
        resolved = []
        for kind, spec, size in places:
            if (kind, spec) in managed:
                continue
            address = place(spec, pid, guest)
            if address % size:
                fail(f"{spec} at {address:#x} is not aligned to its size of {size}, which the debug registers need")
            resolved.append((kind, spec, size, address))
    except LookupError as e:
        fail(str(e))
    print(f"guest-dbg: {label}", file=sys.stderr)
    for kind, spec, size, address in resolved:
        print(f"guest-dbg: {kind} {spec} at {address:#x}" + (f", {size} bytes" if kind not in ("break", "log") else ""), file=sys.stderr)
    watch = None
    if managed == [("log", "jit")]:
        watch, bodies = dotnet.Watch(None, guest, pid, None), None
    elif managed:
        try:
            watch = dotnet.Watch(None, guest, pid, dotnet.Place(managed[0][1]))
            bodies = watch.look()
        except (ValueError, LookupError) as e:
            fail(str(e))
        for found in bodies or []:
            print(f"guest-dbg: {managed[0][0]} {found.label}, its IL at {found.address:#x}, {len(found.il)} bytes"
                  + (", precompiled as ReadyToRun, which the JIT compiles again only once it is hot" if found.precompiled else ""), file=sys.stderr)
        if bodies == []:
            print(f"guest-dbg: no assembly the process has loaded has {managed[0][1][len(dotnet.PREFIX):]} yet, so this waits for one that does",
                  file=sys.stderr)

    def stop_now(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop_now)
    gdb = mi.Gdb(program)
    debugger = Debugger(gdb, guest, pid, roots)
    if watch:
        watch.debugger = debugger
    hits, foreign, pending, ended, missed = 0, 0, None, "timeout", 0

    def record(spec, reader, thread, where):
        extra, label = {}, spec.label
        try:
            data, note = reader.buffer(spec, args.max_bytes)
            if spec.buffer.startswith("corinfo:"):
                method, module, il, _ = reader.method(spec)
                named = watch.name(il, module) if watch else None
                extra = {"method": f"{method:#x}", "module": f"{module:#x}", **({"name": named} if named else {})}
                label = f"{label} {named}" if named else label
        except (LookupError, mi.Failed, ValueError, struct.error) as e:
            data, note = b"", f"not read: {e}"
        name = writer.write(label, thread, where, data, note, extra)
        print(f"log {writer.count}: {label} {len(data)} B, cpu {thread}, {name}{'  (' + note + ')' if note else ''}  "
              f"{STEERING.sub('', logs.preview(data))}")
        sys.stdout.flush()
    elsewhere = collections.Counter()
    try:
        for setting in ("mi-async on", "pagination off", "confirm off", "can-use-hw-watchpoints 1"):
            gdb.run(f"-gdb-set {setting}")
        gdb.run(f"-target-select remote {target}", wait=60)
        gdb.stops.clear()
        names, _ = gdb.run("-data-list-register-names")
        debugger.index = {n: i for i, n in enumerate(names["register-names"]) if n}
        if "cr3" not in debugger.index and roots:
            fail("this debug stub does not show the page table root, so stops cannot be told apart by process")

        numbers = {}
        for kind, spec, size, address in resolved:
            if kind in ("break", "log"):
                values, _ = gdb.run(f"-break-insert -h *{address:#x}")
                numbers[values["bkpt"]["number"]] = (kind, spec)
            else:
                values, _ = gdb.run(f"-break-watch {'-a ' if kind == 'access' else ''}\"*({SIZES[size]} *){address:#x}\"")
                made = values.get("wpt") or values.get("hw-awpt") or values.get("hw-rwpt")
                numbers[made["number"]] = (kind, spec)
        table, _ = gdb.run("-break-list")
        for entry in table["BreakpointTable"]["body"]:
            if entry["type"] not in OURS:
                fail(f"gdb would make {numbers.get(entry['number'], ('', '?'))[1]} a {entry['type']}, which steps through every instruction of the guest")
        def placed(codes, rip=None):
            """Sets the managed place's stop at each new code, its older code's taken away. Gives the stop's number when the
            processor is at that code already, as at compileMethod's first call for --log jit."""
            now = None
            for code in codes:
                # The newest code of a method is the one its callers go to, once the runtime has switched them over.
                for old in [n for n, place in numbers.items() if place == managed[0]]:
                    gdb.run(f"-break-delete {old}")
                    del numbers[old]
                values, _ = gdb.run(f"-break-insert -h *{code:#x}")
                numbers[values["bkpt"]["number"]] = managed[0]
                now = values["bkpt"]["number"] if code == rip else now
            return now

        if watch:
            try:
                codes, said = watch.arm()
            except LookupError as e:
                fail(str(e))
            print(f"guest-dbg: {said}", file=sys.stderr)
            placed(codes)

        deadline = time.monotonic() + args.timeout
        debugger.go()
        while True:
            stop = gdb.stopped(deadline)
            if stop is None:
                break
            debugger.running = False
            number = stop.get("bkptno") or (stop.get("wpt") or stop.get("hw-awpt") or stop.get("hw-rwpt") or {}).get("number")
            regs = debugger.registers(GENERAL)
            mine = not roots or (regs["cr3"] or 0) & ROOT in roots
            ours = number in numbers or (pending and number == pending[0]) or (watch and watch.owns(number))
            if not mine or not ours:
                foreign += 1
                elsewhere[(regs["cr3"] or 0) & ROOT] += 1
                if foreign >= args.busy:
                    ended = "busy"
                    break
                debugger.go()
                continue
            if watch and watch.owns(number):
                codes, said = watch.stop(number, regs)
                if said:
                    print(f"guest-dbg: {said}", file=sys.stderr)
                number = placed(codes, regs["rip"])
                if number is None:
                    debugger.go()
                    continue
            if pending and number == pending[0]:
                if regs["rsp"] != pending[1]:
                    debugger.go()
                    continue
                if pending[3]:
                    spec, entry, thread = pending[3]
                    hits += 1
                    record(spec, logs.Reader(debugger, entry, regs), thread, pending[2])
                else:
                    print(f"returned to {debugger.where(regs['rip'])}, from the stop at {pending[2]}")
                    debugger.show(regs)
                    debugger.commands(args.on_return)
                gdb.run(f"-break-delete {number}")
                pending = None
                if args.hits and hits >= args.hits:
                    ended = "done"
                    break
                debugger.go()
                continue
            if args.hits and hits >= args.hits:
                debugger.go()
                continue
            kind, spec = numbers[number]
            if kind == "log":
                wanted = by_place[spec]
                if not wanted.at_return:
                    hits += 1
                    record(wanted, logs.Reader(debugger, regs, regs), stop.get("thread-id", "?"), debugger.where(regs["rip"]))
                elif pending is None:
                    back = debugger.word(regs["rsp"])
                    values, _ = gdb.run(f"-break-insert -h *{back:#x}")
                    pending = (values["bkpt"]["number"], regs["rsp"] + 8, debugger.where(regs["rip"]), (wanted, regs, stop.get("thread-id", "?")))
                else:
                    missed += 1
                debugger.commands(args.do)
                if args.hits and hits >= args.hits and pending is None:
                    ended = "done"
                    break
                debugger.go()
                continue
            hits += 1
            change = stop.get("value", {})
            values = ", ".join(f"{k} {v}" for k, v in change.items()) if isinstance(change, dict) else ""
            print(f"hit {hits}: {kind} {spec}, at {debugger.where(regs['rip'])}, thread {stop.get('thread-id', '?')}" + (f", {values}" if values else ""))
            debugger.show(regs)
            debugger.commands(args.do)
            if args.on_return and kind == "break" and pending is None:
                back = debugger.word(regs["rsp"])
                values, _ = gdb.run(f"-break-insert -h *{back:#x}")
                pending = (values["bkpt"]["number"], regs["rsp"] + 8, debugger.where(regs["rip"]), None)
            if args.hits and hits >= args.hits:
                for done in numbers:
                    gdb.run(f"-break-delete {done}")
                numbers = {}
                if pending is None:
                    ended = "done"
                    break
            debugger.go()
    except mi.Failed as e:
        ended = f"gdb: {e}"
    except KeyboardInterrupt:
        ended = "stopped"
    finally:
        try:
            if debugger.running:
                gdb.run("-exec-interrupt")
                gdb.stopped(time.monotonic() + 15)
            gdb.run("-break-delete")
            gdb.run("-target-detach")
            gdb.run("-gdb-exit", wait=5)
        except mi.Failed:
            pass
        gdb.close()

    if writer:
        print(f"guest-dbg: {writer.count} buffers in {writer.folder}" + (f", {missed} returns missed while another was waited for" if missed else ""),
              file=sys.stderr)
        if ended == "timeout":
            ended = "done"
    print(f"guest-dbg: {hits} of {args.hits or 'any number of'} stops in the process, {foreign} elsewhere let go, and the guest runs on", file=sys.stderr)
    if hits < args.hits and elsewhere and roots:
        owners = guest.owners() if guest else {}
        print("guest-dbg: the process has the page table roots " + ", ".join(f"{r:#x}" for r in sorted(roots))
              + ", and the stops came from " + ", ".join(f"{r:#x} {owners.get(r, '')} ({n})".replace("  ", " ") for r, n in elsewhere.most_common(4)),
              file=sys.stderr)
    if ended == "done":
        return
    reasons = {"timeout": f"the time of {args.timeout:g} seconds ran out",
               "busy": f"{foreign} stops in other processes, which slows the guest down too much",
               "stopped": "it was stopped"}
    fail(reasons.get(ended, ended))


if __name__ == "__main__":
    main()

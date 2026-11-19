"""guest-dbg: breakpoints and watchpoints in one process of a guest, set from outside through QEMU's debug stub.

Nothing is attached to a process in the guest and nothing is written into its memory. The CPU's debug registers stop
the whole guest at an address, and a stop in any other process than the one asked for is let go at once.
"""
import argparse
import collections
import os
import re
import signal
import sys
import time

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
               "and nt names the kernel. A guest has four debug registers, so four places at most, a return taking one. "
               "Every stop halts the whole guest for a moment, and a place that other processes run through often slows the guest down.")
    parser.add_argument("process", help="a process name or number, cr3=ROOT for a page table root, or - for every process")
    parser.add_argument("--break", dest="breaks", action="append", default=[], metavar="PLACE", help="stop when this code runs")
    parser.add_argument("--watch", action="append", default=[], metavar="PLACE[:SIZE]", help="stop when this is written with another value, SIZE 1, 2, 4 or 8")
    parser.add_argument("--access", action="append", default=[], metavar="PLACE[:SIZE]", help="stop when this is read or written")
    parser.add_argument("--do", action="append", default=[], metavar="COMMAND", help="a gdb command at each stop, as x/8gx $rsp or set $rax = 0")
    parser.add_argument("--on-return", action="append", default=[], metavar="COMMAND",
                        help="a gdb command when the function a --break stopped in returns, which takes one debug register")
    parser.add_argument("--hits", type=int, default=1, help="stops in the process to wait for, 1 by default")
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
        values, _ = self.gdb.run(f"-data-read-memory-bytes {address:#x} 8")
        return int.from_bytes(bytes.fromhex(values["memory"][0]["contents"]), "little")

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
    used = len(args.breaks) + len(args.watch) + len(args.access) + (1 if args.on_return else 0)
    if not used:
        fail("there is nothing to stop at: give --break, --watch or --access")
    if used > 4:
        fail(f"that takes {used} debug registers and a guest has four")
    if args.on_return and not args.breaks:
        fail("--on-return goes with a --break")
    target = os.environ.get("VM_INSPECT_GDB")
    if not target:
        fail("this runs in a session that has QEMU's debug stub open, as vm-lab opens it")

    places = [("break", spec, 1) for spec in args.breaks]
    for kind, specs in (("watch", args.watch), ("access", args.access)):
        for spec in specs:
            head, _, size = spec.rpartition(":") if re.search(r":\d+$", spec) else (spec, "", "8")
            if int(size) not in SIZES:
                fail(f"{spec}: a size is 1, 2, 4 or 8 bytes")
            places.append((kind, head, int(size)))

    raw = args.process == "-" or args.process.startswith("cr3=")
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
            address = place(spec, pid, guest)
            if address % size:
                fail(f"{spec} at {address:#x} is not aligned to its size of {size}, which the debug registers need")
            resolved.append((kind, spec, size, address))
    except LookupError as e:
        fail(str(e))
    print(f"guest-dbg: {label}", file=sys.stderr)
    for kind, spec, size, address in resolved:
        print(f"guest-dbg: {kind} {spec} at {address:#x}" + (f", {size} bytes" if kind != "break" else ""), file=sys.stderr)

    def stop_now(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop_now)
    gdb = mi.Gdb(program)
    debugger = Debugger(gdb, guest, pid, roots)
    hits, foreign, pending, ended = 0, 0, None, "timeout"
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
            if kind == "break":
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
            if not mine or (number not in numbers and (not pending or number != pending[0])):
                foreign += 1
                elsewhere[(regs["cr3"] or 0) & ROOT] += 1
                if foreign >= args.busy:
                    ended = "busy"
                    break
                debugger.go()
                continue
            if pending and number == pending[0]:
                if regs["rsp"] != pending[1]:
                    debugger.go()
                    continue
                print(f"returned to {debugger.where(regs['rip'])}, from the stop at {pending[2]}")
                debugger.show(regs)
                debugger.commands(args.on_return)
                gdb.run(f"-break-delete {number}")
                pending = None
                if hits >= args.hits:
                    ended = "done"
                    break
                debugger.go()
                continue
            if hits >= args.hits:
                debugger.go()
                continue
            hits += 1
            kind, spec = numbers[number]
            change = stop.get("value", {})
            values = ", ".join(f"{k} {v}" for k, v in change.items()) if isinstance(change, dict) else ""
            print(f"hit {hits}: {kind} {spec}, at {debugger.where(regs['rip'])}, thread {stop.get('thread-id', '?')}" + (f", {values}" if values else ""))
            debugger.show(regs)
            debugger.commands(args.do)
            if args.on_return and kind == "break" and pending is None:
                back = debugger.word(regs["rsp"])
                values, _ = gdb.run(f"-break-insert -h *{back:#x}")
                pending = (values["bkpt"]["number"], regs["rsp"] + 8, debugger.where(regs["rip"]))
            if hits >= args.hits:
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

    print(f"guest-dbg: {hits} of {args.hits} stops in the process, {foreign} elsewhere let go, and the guest runs on", file=sys.stderr)
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

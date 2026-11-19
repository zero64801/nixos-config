"""guest-mcp: a program in the guest that speaks in lines of JSON, joined to this tool's own input and output.

That is how an MCP server which lives in the guest is used from this side: whoever starts guest-mcp talks to it
as to a server of its own. The program runs in the guest as a job that reads what is added to one file and
answers into another. A line for it goes in with one short command, which then waits for the answer and brings
it back, so each thing asked of the program is one line in the session's log.

What the program answers was written by the guest. Each line is read as JSON here and written out anew, so that
what goes on is whole, of a bounded size, and free of anything a terminal acts on. What it says is still the guest's.
"""
import argparse
import base64
import json
import os
import queue
import secrets
import shlex
import signal
import subprocess
import sys
import threading
import time

import programs
from agent import STEERING, WRITE, Guest, decoded, plain, shape
from session import Refused, fail

# The longest line that is passed on. An answer can hold a whole decompiled program, and no more than that.
LINE = 32 * 1024 * 1024
# A line longer than this does not fit a command and is added to the program's file instead, where the log shows none of it.
SPOKEN = 12000
# How long an answer is waited for in one go, and how long nothing has to happen before a look is kept open for what the program says unasked.
PATIENCE, QUIET = 600, 2
# For a guest with a shell. $1 the job's files, $2 the place, $3 a line or nothing, $4 how often to look, 20 times a second.
TELL = '''[ -z "$3" ] || printf '%s\\n' "$3" >> "$1.in"
n=0
while [ "$(wc -c < "$1.out")" -le "$2" ] && [ "$n" -lt "$4" ]; do sleep 0.05; n=$((n + 1)); done
sleep 0.02
tail -c "+$(($2 + 1))" "$1.out" | head -c 8388608'''


def cleaned(value, depth=0):
    """What a line holds, with every text in it free of what a terminal acts on."""
    if depth > 200:
        raise RecursionError
    if isinstance(value, str):
        return STEERING.sub("", value)
    if isinstance(value, list):
        return [cleaned(item, depth + 1) for item in value]
    if isinstance(value, dict):
        return {STEERING.sub("", name): cleaned(item, depth + 1) for name, item in value.items()}
    return value


def answered(message):
    """The names of the questions a message answers."""
    several = message if isinstance(message, list) else [message]
    return {json.dumps(one.get("id")) for one in several if isinstance(one, dict) and "id" in one and "method" not in one}


def asking(message):
    """The names of the questions a message asks, each of which an answer is owed for."""
    several = message if isinstance(message, list) else [message]
    return {json.dumps(one.get("id")) for one in several if isinstance(one, dict) and "id" in one and "method" in one}


def serve(args):
    guest = Guest()
    if not args.command:
        fail("the program to talk to is missing")
    for pair in args.env:
        if "=" not in pair[1:]:
            fail(f"--env takes NAME=VALUE, not {pair}")
    whom, job, windows = programs.account(guest, args), secrets.token_hex(3), guest.windows()
    if windows:
        home, files = f"{programs.HOME}\\jobs", f"{programs.HOME}\\jobs\\{job}"
        argv = programs.on_windows(args.command[0], subprocess.list2cmdline(args.command), whom, args, job=job, fed=True, env=args.env)
        started = programs.helped(guest, lambda: guest.run(argv))
    else:
        home, files = programs.JOBS, f"{programs.JOBS}/{job}"
        argv = programs.elsewhere(shlex.join(args.command), whom, args, job=job, fed=True, env=args.env)
        started = guest.run(argv)
    if started[0] != 0:
        fail(f"the program could not be started: {plain(started[1] + started[2]).strip()[:300]}")
    code = None
    # Where in the program's answers this is, and what of a line has come so far.
    read, held, lost = 0, b"", False
    owed, looks = set(), []

    def ended():
        if not guest.exists(files + ".exit"):
            return None
        said = plain(guest.read(files + ".exit", 0, 64)[0]).strip()
        return int(said) if said.lstrip("-").isdigit() else 1

    def look(line=None, seconds=0.0):
        """Starts a look at what the program has answered from here on, after handing it a line when there is one."""
        if windows:
            words = [programs.helper(), "tell", "--job", files, "--from", str(read), "--seconds", str(seconds)] + ([line] if line else [])
        else:
            words = ["/bin/sh", "-c", TELL, "sh", files, str(read), line or "", str(int(seconds * 20))]
        looks.append((shape(guest.ask("exec", path=words[0], arg=words[1:], capture_output=True), "pid", kind=int), read))

    def passed_on(line):
        if not line.strip():
            return
        try:
            said = cleaned(json.loads(line))
        except (ValueError, RecursionError):
            said = None
        if not isinstance(said, (dict, list)):
            print("guest-mcp: a line that is no message was left out", file=sys.stderr)
            return
        owed.difference_update(answered(said))
        sys.stdout.write(json.dumps(said, ensure_ascii=True, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    def taken(data, since):
        """Passes on what a look brought, less what an earlier look had already brought."""
        nonlocal read, held, lost
        data = data[read - since:] if since <= read else b""
        if not data:
            return False
        read += len(data)
        *whole, held = (held + data).split(b"\n")
        for line in whole:
            if lost:
                lost = False
            else:
                passed_on(line)
        if len(held) > LINE:
            print("guest-mcp: a line longer than this passes on was left out", file=sys.stderr)
            held, lost = b"", True
        return True

    def stop(*_):
        raise SystemExit(0)

    for sign in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sign, stop)
    try:
        lines = queue.SimpleQueue()

        def heard():
            # Read as it comes and not through Python's own buffer, which a thread that waits in it would hold locked when the rest wants to end.
            kept = b""
            while True:
                more = os.read(0, 65536)
                if not more:
                    break
                *whole, kept = (kept + more).split(b"\n")
                for line in whole:
                    lines.put(line + b"\n")
            if kept:
                lines.put(kept)
            lines.put(None)

        threading.Thread(target=heard, daemon=True).start()
        pause, checked, stirred, talking = 0.004, time.monotonic(), time.monotonic(), True
        while talking and code is None:
            try:
                line = lines.get(timeout=pause)
            except queue.Empty:
                line = b""
            pause = min(pause * 1.3, 0.1 if looks else 0.25)
            while line or line is None:
                if line is None:
                    talking = False
                    break
                text = line.decode("utf-8", "replace").strip()
                if text:
                    try:
                        asked = asking(json.loads(text))
                    except (ValueError, RecursionError):
                        asked = set()
                    owed.update(asked)
                    if len(text) <= SPOKEN:
                        look(text, PATIENCE if asked else 0.3)
                    else:
                        handle = shape(guest.ask("file-open", path=files + ".in", mode="a"), kind=int)
                        for at in range(0, len(line), WRITE):
                            guest.ask("file-write", handle=handle, buf_b64=base64.b64encode(line[at:at + WRITE]).decode())
                        guest.ask("file-close", handle=handle)
                        look(None, PATIENCE if asked else 0.3)
                    pause, stirred = 0.004, time.monotonic()
                line = b"" if lines.empty() else lines.get()
            for pid, since in list(looks):
                status = guest.status(pid)
                if status is not None:
                    looks.remove((pid, since))
                    if taken(decoded(status.get("out-data", "")), since):
                        pause, stirred = 0.004, time.monotonic()
            # An answer that is still owed is waited for.
            # With none owed a look is kept open once things are quiet, for what the program says without being asked.
            if talking and not looks and (owed or time.monotonic() - stirred > QUIET):
                look(None, PATIENCE)
            if time.monotonic() - checked > 1:
                code, checked = ended(), time.monotonic()
        if code is not None:
            print(f"guest-mcp: the program in the guest ended with {code}: {told(guest, files)}", file=sys.stderr)
    finally:
        try:
            # A look that still waits would go on waiting in the guest for an answer nobody takes.
            for pid, _ in looks:
                guest.stop(pid)
            if code is None:
                guest.script(*programs.STOP, home, job)
            guest.run(["cmd.exe", "/d", "/c", "del", "/f", "/q", files + ".*"] if windows else ["/bin/sh", "-c", f"rm -f {files}.*"])
        except (Refused, SystemExit):
            pass
    sys.exit(code or 0)


def told(guest, files):
    """The end of what the program complained of."""
    try:
        return plain(programs.ending(guest, files + ".log", 4096)).strip()[-600:] or "it said nothing"
    except (Refused, SystemExit):
        return "it left no word"


def main():
    parser = argparse.ArgumentParser(prog="guest-mcp", description="Start a program in the guest that speaks in lines of JSON, as an MCP server does, "
                                     "and join it to this tool's own input and output.",
                                     epilog="It works through the agent in the guest, so the session has to be opened with --control. "
                                            "What it prints was written by the guest.")
    parser.add_argument("--as-user", action="store_true", help="as the user who is logged in, and in Windows on their desktop. The agent's own account otherwise")
    parser.add_argument("--user", metavar="NAME", help="as this account, which in Windows has to be logged in")
    parser.add_argument("--elevated", action="store_true", help="with the administrator's rights of that user, in Windows")
    parser.add_argument("--cwd", help="the folder to run it in")
    parser.add_argument("--env", action="append", default=[], metavar="NAME=VALUE", help="something for its environment, as often as needed")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="the program and its arguments")
    try:
        serve(parser.parse_args(sys.argv[2:]))
    except Refused as e:
        fail(str(e))


if __name__ == "__main__":
    main()

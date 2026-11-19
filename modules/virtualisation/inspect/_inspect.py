"""Opens a running guest for inspection and runs a command that can reach its memory.

The guest's memory arrives as a descriptor from the root helper. Programs get at it through sockets in a folder of the
session: one hands the descriptor to whoever connects, one answers the one question LeechCore asks QEMU, where the
memory sits in the guest's address space, and one passes requests for a picture of the screen, for input or for the
agent in the guest on to the helper, which is the side that decides. What goes through it is written down in
~/.local/state/vm-inspect/DOMAIN.log, for the user to read what a tool did to the guest. A guest that shares frames through Looking Glass gets one more, which hands out
the memory they are in. All end with the command.
"""
import argparse
import base64
import glob
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

# The helper's limit, kept here too so that a request it would end the session over never reaches it.
REQUEST = 120 * 1024
GREETING = {"QMP": {"version": {"qemu": {"major": 0, "minor": 0, "micro": 0}, "package": "vm-inspect"}, "capabilities": []}}


def fail(message):
    print(f"vm-inspect: {message}", file=sys.stderr)
    sys.exit(1)


def listen(path):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(8)
    return server


def serve(server, answer):
    while True:
        try:
            conn, _ = server.accept()
        except OSError:
            return
        threading.Thread(target=answer, args=(conn,), daemon=True).start()


def hand_over(ram):
    def answer(conn):
        with conn:
            try:
                socket.send_fds(conn, [b"F"], [ram])
            except OSError:
                pass
    return answer


def memory_map(mtree):
    """Stands in for a QEMU monitor, with the one answer that tells where the guest's memory is mapped."""
    text = "\r\n".join(mtree.splitlines()) + "\r\n"

    def reply(request):
        command = request.get("execute")
        if command == "qmp_capabilities":
            return {"return": {}}
        if command == "human-monitor-command" and request.get("arguments", {}).get("command-line") == "info mtree -f":
            return {"return": text}
        return {"error": {"class": "CommandNotFound", "desc": "this socket only tells where the guest's memory is mapped"}}

    def answer(conn):
        with conn, conn.makefile("rwb") as stream:
            try:
                stream.write(json.dumps(GREETING).encode() + b"\r\n")
                stream.flush()
                for line in stream:
                    try:
                        request = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(request, dict):
                        continue
                    stream.write(json.dumps({**reply(request), "id": request.get("id")}).encode() + b"\r\n")
                    stream.flush()
            except OSError:
                pass
    return answer


def read_line(conn, limit=REQUEST):
    """One line and the descriptors that came with it. None when the other end closed or sent too much."""
    line, descriptors = b"", []
    while not line.endswith(b"\n"):
        if len(line) > limit:
            return None, descriptors
        more, received, _, _ = socket.recv_fds(conn, 4096, 4)
        descriptors += received
        if not more:
            return None, descriptors
        line += more
    return line, descriptors


# Asked over and over while a file moves or a program is waited for, which would bury what the log is for.
UNRECORDED = ("guest-ping", "guest-exec-status", "guest-file-read", "guest-file-write", "guest-file-seek", "guest-file-flush", "guest-file-close")
STEERING = re.compile(r"[\x00-\x1f\x7f-\x9f]")
# A script handed to PowerShell and the values that go with it, both unreadable as they are sent.
ENCODED = re.compile(r"(?<=-EncodedCommand )[A-Za-z0-9+/=]{8,}")
PACKED = re.compile(r"\[Convert\]::FromBase64String\('([A-Za-z0-9+/=]*)'\)")


def asked(request):
    """What a request wants of the guest, in a few words. None for one that is not worth a line."""
    try:
        request = json.loads(request)
    except ValueError:
        return "something that is no request"
    if not isinstance(request, dict):
        return "something that is no request"
    if request.get("do") == "input" and isinstance(request.get("events"), list):
        # What goes down comes up again, which says nothing new.
        said = [f"{e.get('type')} {e.get('key') or e.get('button') or e.get('axis')}{'' if 'down' in e else ' ' + str(e.get('value'))}"
                for e in request["events"][:8] if isinstance(e, dict) and e.get("down") is not False]
        return "input: " + ", ".join(said) if said else None
    if request.get("do") == "disk":
        return f"a file plugged into the guest as a disk it may {'write' if request.get('write') is True else 'read'}"
    if request.get("do") == "push":
        return f"push {request.get('size')} bytes into the file held as {request.get('handle')}"
    if request.get("do") != "agent":
        return str(request.get("do"))
    execute, arguments = str(request.get("execute")), request.get("arguments")
    if execute in UNRECORDED:
        return None
    arguments = arguments if isinstance(arguments, dict) else {}
    words = [str(arguments.get("path", ""))] + [str(word) for word in (arguments.get("arg") or []) if isinstance(arguments.get("arg"), list)]
    said = ENCODED.sub(lambda found: readable(found.group(0), "utf-16-le"), " ".join(words))
    said = PACKED.sub(lambda found: readable(found.group(1), "utf-8"), said)
    return f"{execute} {said} {arguments.get('mode', '')}".strip()


def readable(sent, encoding):
    try:
        return base64.b64decode(sent).decode(encoding, "replace")
    except ValueError:
        return sent


def record(log, request, reply):
    """Adds a line to the session's log, which is the user's to read: what was asked of the guest, and how it went."""
    what = asked(request)
    if log is None or what is None:
        return
    try:
        refused = json.loads(reply).get("error") if reply else "the session ended"
    except (ValueError, AttributeError):
        refused = "an answer that makes no sense"
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {STEERING.sub(' ', what)[:600]} -> {'done' if refused is None else 'refused: ' + STEERING.sub(' ', str(refused))[:200]}\n"
    try:
        if os.path.exists(log) and os.path.getsize(log) > 8 * 1024 * 1024:
            os.replace(log, log + ".1")
        with open(os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "w") as f:
            f.write(line)
    except OSError:
        pass


def control(helper, log):
    """Passes one request per connection to the helper. One at a time, since its answers come back in order."""
    turn = threading.Lock()

    def answer(conn):
        with conn:
            descriptors = []
            try:
                conn.settimeout(10)
                request, descriptors = read_line(conn)
                if request is None or len(descriptors) > 1:
                    conn.sendall(json.dumps({"error": "a request is one line of at most 120 KiB, with one file at most"}).encode() + b"\n")
                    return
                with turn:
                    # A file to push travels on with its request.
                    if descriptors:
                        socket.send_fds(helper, [request], descriptors)
                        os.close(descriptors.pop())
                    else:
                        helper.sendall(request)
                    reply, descriptors = read_line(helper)
                    record(log, request, reply)
                if reply is None:
                    return
                if descriptors:
                    socket.send_fds(conn, [reply], descriptors)
                else:
                    conn.sendall(reply)
            except OSError:
                pass
            finally:
                for descriptor in descriptors:
                    os.close(descriptor)
    return answer


def session_log(domain):
    """Where the session writes what tools asked of the guest. None when there is no place for it."""
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    try:
        os.makedirs(os.path.join(state, "vm-inspect"), mode=0o700, exist_ok=True)
    except OSError:
        return None
    return os.path.join(state, "vm-inspect", f"{domain}.log")


def session_env(domain, folder, gdb):
    env = dict(os.environ)
    env["VM_INSPECT_DOMAIN"] = domain
    env["VM_INSPECT_DIR"] = folder
    env["VM_INSPECT_DEVICE"] = f"qemu://ram={folder}/ram.sock,qmp={folder}/qmp.sock"
    if gdb:
        env["VM_INSPECT_GDB"] = gdb
    else:
        env.pop("VM_INSPECT_GDB", None)
    return env


def join(domain, folder, command):
    """Runs the command against a session another vm-inspect has open, for a second terminal or a sandbox it is shared with."""
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.connect(os.path.join(folder, "ram.sock"))
    except OSError:
        fail(f"{domain} has no session open here, start one with vm-inspect {domain}")
    finally:
        probe.close()
    stubs = [p for p in sorted(glob.glob(f"/run/vm-inspect/{glob.escape(domain)}.*/gdb.sock")) if os.access(p, os.R_OK | os.W_OK)]
    try:
        os.execvpe(command[0], command, session_env(domain, folder, stubs[0] if stubs else None))
    except OSError as e:
        fail(str(e))


def main():
    parser = argparse.ArgumentParser(
        prog="vm-inspect",
        usage="vm-inspect [--gdb] [--control] DOMAIN [-- COMMAND...] | vm-inspect --join DOMAIN [-- COMMAND...]",
        description="Open a running guest for inspection and run COMMAND, or a shell, with its memory in reach.",
        epilog="Inside, $VM_INSPECT_DEVICE is the LeechCore device (memprocfs -device \"$VM_INSPECT_DEVICE\" -mount DIR) "
               "and, with --gdb, $VM_INSPECT_GDB is QEMU's debug socket (gdb -ex \"target remote $VM_INSPECT_GDB\"). "
               "The guest stops while a debugger is attached, so detach before you quit it. "
               "guest-shot saves a picture of the guest's screen, and with --control guest-input sends it keys and pointer events.")
    parser.add_argument("settings", help=argparse.SUPPRESS)
    parser.add_argument("--gdb", action="store_true", help="also open QEMU's debug stub for the session")
    parser.add_argument("--control", action="store_true",
                        help="also let the session send keys and pointer events to the guest and talk to the agent in it")
    parser.add_argument("--join", action="store_true", help="use the session that is already open, without opening the guest again")
    parser.add_argument("domain")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    with open(args.settings) as f:
        settings = json.load(f)
    if args.domain not in settings["domains"]:
        fail(f"{args.domain} is not among the domains that may be inspected ({', '.join(settings['domains']) or 'none'})")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    command = command or [os.environ.get("SHELL") or "/bin/sh"]
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        fail("XDG_RUNTIME_DIR is not set")
    folder = os.path.join(runtime, "vm-inspect", args.domain)
    if args.join:
        join(args.domain, folder, command)

    ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    options = (["--gdb"] if args.gdb else []) + (["--control"] if args.control else [])
    helper = subprocess.Popen([settings["pkexec"], settings["helper"], args.domain] + options, stdin=theirs)
    theirs.close()
    try:
        _, descriptors, _, _ = socket.recv_fds(ours, 1, 2)
    except OSError:
        descriptors = []
    if not descriptors:
        helper.wait()
        sys.exit(helper.returncode or 1)
    ram = descriptors[0]
    with ours.makefile("rb") as stream:
        info = json.loads(stream.readline())

    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder, mode=0o700)
    servers = [(listen(os.path.join(folder, "ram.sock")), hand_over(ram)),
               (listen(os.path.join(folder, "qmp.sock")), memory_map(info["mtree"])),
               (listen(os.path.join(folder, "control.sock")), control(ours, session_log(args.domain)))]
    if len(descriptors) > 1:
        servers.append((listen(os.path.join(folder, "frames.sock")), hand_over(descriptors[1])))
    for server, answer in servers:
        threading.Thread(target=serve, args=(server, answer), daemon=True).start()

    # A session ended from outside still closes the guest and takes its folder along.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda number, _: sys.exit(128 + number))
    status, child = 1, None
    try:
        child = subprocess.Popen(command, env=session_env(args.domain, folder, info["gdb"]))
        status = child.wait()
    except OSError as e:
        print(f"vm-inspect: {e}", file=sys.stderr)
    except KeyboardInterrupt:
        status = 130
    finally:
        if child and child.poll() is None:
            child.terminate()
        for server, _ in servers:
            server.close()
        shutil.rmtree(folder, ignore_errors=True)
        ours.close()
        try:
            helper.wait(timeout=60)
        except subprocess.TimeoutExpired:
            pass
    sys.exit(status)


if __name__ == "__main__":
    main()

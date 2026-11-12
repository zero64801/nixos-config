"""Opens a running guest for inspection and runs a command that can reach its memory.

The guest's memory arrives as a descriptor from the root helper. Programs get at it through two sockets in a folder of
the session: one hands the descriptor to whoever connects, the other answers the one question LeechCore asks QEMU, where
the memory sits in the guest's address space. Both end with the command.
"""
import argparse
import glob
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading

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
        usage="vm-inspect [--gdb | --join] DOMAIN [-- COMMAND...]",
        description="Open a running guest for inspection and run COMMAND, or a shell, with its memory in reach.",
        epilog="Inside, $VM_INSPECT_DEVICE is the LeechCore device (memprocfs -device \"$VM_INSPECT_DEVICE\" -mount DIR) "
               "and, with --gdb, $VM_INSPECT_GDB is QEMU's debug socket (gdb -ex \"target remote $VM_INSPECT_GDB\"). "
               "The guest stops while a debugger is attached, so detach before you quit it.")
    parser.add_argument("settings", help=argparse.SUPPRESS)
    parser.add_argument("--gdb", action="store_true", help="also open QEMU's debug stub for the session")
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
    helper = subprocess.Popen([settings["pkexec"], settings["helper"], args.domain] + (["--gdb"] if args.gdb else []), stdin=theirs)
    theirs.close()
    try:
        _, descriptors, _, _ = socket.recv_fds(ours, 1, 1)
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
               (listen(os.path.join(folder, "qmp.sock")), memory_map(info["mtree"]))]
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

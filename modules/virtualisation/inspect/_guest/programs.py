"""Programs run in the guest: waited for or left to run as a job, as the agent's own account or as a user's.

The agent starts what it is given as the system's own account. In Windows that account has no desktop, so a
program that is to see windows or send input has to be started as the user who is logged in, on their desktop.
That takes a small helper inside the guest, helper.cs next to this file, which the guest compiles itself the
first time it is needed. Elsewhere su does it.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import re
import secrets
import shlex
import subprocess
import sys

from agent import POWERSHELL, SHOWN, UTF8, WRITE, Guest, plain, shape, show
from session import Refused, fail

# Only the system account and administrators can write here, so nothing a user plants is run as the system.
HOME = r"C:\Windows\System32\config\systemprofile\AppData\Local\vm-inspect"
COMPILER = r"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
SOURCE = pathlib.Path(__file__).with_name("helper.cs")
JOBS = "/run/vm-inspect-jobs"
JOB = re.compile(r"[0-9a-f]{6}")
# Starts the job script $1 in a shell of its own, holding none of the agent's pipes, and waits until it has written $2.
DETACH = '''/bin/sh -c "$1" sh < /dev/null > /dev/null 2>&1 &
n=0
while [ ! -s "$2" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
[ -s "$2" ]'''
# Windows takes 32767 characters, and the line travels inside the helper's own.
LINE = 12000
# Where Python's own installer puts it, for a guest that has it on no path.
PYTHONS = [r"%LOCALAPPDATA%\Programs\Python\Python3*\python.exe", r"%ProgramFiles%\Python3*\python.exe", r"%SystemDrive%\Python3*\python.exe",
           r"%SystemDrive%\Users\*\AppData\Local\Programs\Python\Python3*\python.exe"]
WINDOWS = 300

STATUS = (("Get-ChildItem -LiteralPath $a[0] -Filter ($a[1] + '.pid') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object { "
          "$files = Join-Path $a[0] $_.BaseName; "
          "$state = if (Test-Path -LiteralPath ($files + '.exit')) { $end = (Get-Content -LiteralPath ($files + '.exit') -Raw).Trim(); if ($end -eq 'stopped') { $end } else { 'exit ' + $end } } "
          "elseif (Get-Process -Id ([int](Get-Content -LiteralPath $_.FullName -Raw)) -ErrorAction SilentlyContinue) { 'running' } else { 'gone' }; "
          "'{0}  {1}' -f $_.BaseName, $state }"),
          '''cd "$1" 2>/dev/null || exit 0
for f in $2.pid; do
  [ -e "$f" ] || continue
  id=${f%.pid}
  if [ -e "$id.exit" ]; then end=$(cat "$id.exit"); [ "$end" = stopped ] && state=stopped || state="exit $end"
  elif kill -0 "$(cat "$f")" 2>/dev/null; then state=running
  else state=gone; fi
  echo "$id  $state"
done''')
# Whether the job had ended is looked at before the stop, since a job that is being stopped can still write down an end of its own.
STOP = (("$files = Join-Path $a[0] $a[1]; $ended = Test-Path -LiteralPath ($files + '.exit'); "
         "& taskkill.exe /pid ([int](Get-Content -LiteralPath ($files + '.pid') -Raw)) /t /f | Out-Null; "
         "if (-not $ended) { Set-Content -LiteralPath ($files + '.exit') -Value 'stopped' }; 'stopped'"),
        # By who started whom and not by group, since the su of most systems gives what it starts a session of its own.
        '''cd "$1" && pid=$(cat "$2.pid") || exit 1
ended=0
[ -e "$2.exit" ] && ended=1
tree() { for child in $(pgrep -P "$1"); do tree "$child"; done; echo "$1"; }
alive() { for one in $all; do kill -0 "$one" 2>/dev/null && return 0; done; return 1; }
all=$(tree "$pid")
kill -TERM $all 2>/dev/null
n=0
while alive && [ "$n" -lt 20 ]; do sleep 0.1; n=$((n + 1)); done
kill -KILL $all 2>/dev/null
[ "$ended" = 1 ] || echo stopped > "$2.exit"
echo stopped''')
CLEAN = (("Get-ChildItem -LiteralPath $a[0] -Filter '*.pid' -ErrorAction SilentlyContinue | ForEach-Object { $files = Join-Path $a[0] $_.BaseName; "
         "if ((Test-Path -LiteralPath ($files + '.exit')) -or -not (Get-Process -Id ([int](Get-Content -LiteralPath $_.FullName -Raw)) -ErrorAction SilentlyContinue)) { "
         "Remove-Item -LiteralPath ($files + '.pid'), ($files + '.log'), ($files + '.exit') -ErrorAction SilentlyContinue; $_.BaseName } }"),
         '''cd "$1" 2>/dev/null || exit 0
for f in *.pid; do
  [ -e "$f" ] || continue
  id=${f%.pid}
  if [ -e "$id.exit" ] || ! kill -0 "$(cat "$f")" 2>/dev/null; then rm -f "$id.pid" "$id.log" "$id.exit"; echo "$id"; fi
done''')
# $1 process or file, $2 its name, $3 is 0 to wait for it and 1 to wait for it to be gone, $4 how often to look.
# A process that has ended and only waits for its parent to collect it does not count as running.
WAIT = '''n=0
while :; do
  there=1
  if [ "$1" = process ]; then
    for pid in $(pgrep -x "$2" 2>/dev/null); do
      grep -qs "^State:[[:space:]]*Z" "/proc/$pid/status" || there=0
    done
  elif [ -e "$2" ]; then
    there=0
  fi
  [ "$there" -eq "$3" ] && exit 0
  [ "$n" -ge "$4" ] && exit 1
  sleep 0.2
  n=$((n + 1))
done'''


def helper():
    """Where the helper is in a Windows guest. Its name carries what it was built from, so a changed one is built anew."""
    return f"{HOME}\\helper-{hashlib.sha256(SOURCE.read_bytes()).hexdigest()[:16]}.exe"


def build(guest):
    exe = helper()
    source, made = exe[:-4] + ".cs", exe[:-4] + ".tmp"
    guest.run(["cmd.exe", "/d", "/c", "mkdir", f"{HOME}\\jobs"])
    guest.run(["cmd.exe", "/d", "/c", "del", "/f", "/q", f"{HOME}\\helper-*"])
    guest.write(source, SOURCE.read_bytes())
    try:
        # The compiler marks a program as made for a Windows of long ago unless told otherwise, and Windows then tells it where a window's edges were in that one.
        code, out, err, _ = guest.run([COMPILER, "/nologo", "/optimize", "/subsystemversion:6.00", "/r:System.Drawing.dll", "/r:System.Core.dll", f"/out:{made}", source], timeout=120)
    except Refused:
        fail("this Windows guest lacks the compiler of the .NET Framework 4, which its helper is built with")
    if code == 0:
        # Under its name only once it is whole, so that a half written one is never taken for it.
        code, out, err, _ = guest.run(["cmd.exe", "/d", "/c", "move", "/y", made, exe])
    if code != 0:
        fail(f"the helper for this Windows guest could not be built: {plain(out + err).strip()[:400]}")


def helped(guest, call):
    """What a call that starts the Windows helper gives. A guest that does not have the helper yet builds it first."""
    try:
        return call()
    except Refused:
        if guest.exists(helper()):
            raise
        build(guest)
        return call()


def ending(guest, path, most):
    """The last bytes of a file of the guest that a program there may still be writing."""
    if not guest.windows():
        return guest.read(path, max(guest.size(path) - most, 0), most)[0]
    # The agent of a Windows guest cannot open a file that is open for writing, and the helper can.
    code, out, err, _ = helped(guest, lambda: guest.run([helper(), "read", "--file", path, "--from", str(-most), "--seconds", "0"]))
    if code != 0:
        fail(plain(err).strip()[:300] or f"{path} cannot be read")
    return out


def account(guest, args):
    """Whom a program is to run as: None for the agent's own account, an empty name for whoever is at a Windows desktop."""
    if args.elevated and not (guest.windows() and (args.user or args.as_user)):
        fail("--elevated goes with --as-user or --user, in a Windows guest")
    if args.user or not args.as_user:
        return args.user or None
    if guest.windows():
        return ""
    names = [user.get("user") for user in shape(guest.ask("get-users"), kind=list) if isinstance(user, dict)]
    names = [name for name in names if isinstance(name, str) and name]
    if not names:
        fail("nobody is logged in to the guest. Name an account with --user")
    return names[0]


def on_windows(program, line, whom, args, grant=(), delete=(), job=None, fed=False, env=()):
    """The helper's words for starting a program in a Windows guest."""
    if len(line) > LINE:
        fail("that is too long for one command line. Push it as a file and run the file")
    words = [helper(), "run"]
    if whom is not None:
        words += ["--user", whom] if whom else ["--desktop"]
        for path in grant:
            words += ["--grant", path]
    if args.elevated:
        words.append("--elevated")
    if args.cwd:
        words += ["--cwd", args.cwd]
    for path in delete:
        words += ["--delete", path]
    for pair in env:
        words += ["--env", pair]
    if job:
        words += ["--job", f"{HOME}\\jobs\\{job}"] + (["--feed"] if fed else [])
    return [*words, program, line]


def elsewhere(line, whom, args, grant=(), delete=(), job=None, fed=False, env=()):
    """A shell's words for starting a line in a guest that has one."""
    if env:
        line = f"env {shlex.join(env)} {line}"
    if args.cwd:
        line = f"cd {shlex.quote(args.cwd)} && {line}"
    if whom:
        # Where a desktop keeps its sockets, which a program started for a user looks up.
        line = f'[ -d "/run/user/$(id -u)" ] && export XDG_RUNTIME_DIR="/run/user/$(id -u)"; {line}'
        # In this order for the su of busybox, which takes its own options only before the name.
        line = f"su -s /bin/sh {shlex.quote(whom)} -c {shlex.quote(line)}"
        if grant:
            line = f"chmod a+r {shlex.join(grant)} && {line}"
    if delete:
        line = f"{line}\ncode=$?\nrm -f {shlex.join(delete)}\nexit $code"
    if not job:
        return ["/bin/sh", "-c", line]
    files = f"{JOBS}/{job}"
    begun = f"mkdir -p -m 700 {JOBS} && echo $$ > {files}.pid.new && mv {files}.pid.new {files}.pid && rm -f {files}.exit\n"
    if fed:
        # What is added to one file reaches the program as what it reads, and its answers are kept apart from its complaints.
        script = (f"{begun}: >> {files}.in; mkfifo {files}.fifo; tail -n +1 -f {files}.in > {files}.fifo & feeder=$!\n"
                  f"( {line}\n) < {files}.fifo > {files}.out 2> {files}.log\ncode=$?; kill $feeder; rm -f {files}.fifo; echo $code > {files}.exit")
    else:
        script = f"{begun}( {line}\n) > {files}.log 2>&1 < /dev/null\necho $? > {files}.exit"
    # The job runs in a shell of its own, and the one the agent started ends once the job has begun, for the reason Guest.forget gives.
    return ["/bin/sh", "-c", DETACH, "sh", script, f"{files}.pid"]


def carried_out(tool, guest, args, argv, given=None, job=None, leftover=None):
    """Starts what was put together and shows how it went, or says under which name it was left to run."""
    if job and given is not None:
        fail("a job is given nothing to read")
    start = lambda: guest.run(argv, given, 60 if job else args.timeout)
    try:
        result = helped(guest, start) if guest.windows() else start()
    except (Refused, SystemExit):
        # What was to clear the script away never ran or was stopped.
        if leftover:
            try:
                guest.run(["cmd.exe", "/d", "/c", "del", "/f", "/q", leftover] if guest.windows() else ["rm", "-f", leftover])
            except (Refused, SystemExit):
                pass
        raise
    if job:
        code, out, err, _ = result
        if code != 0:
            fail(f"the job could not be started: {plain(out + err).strip()[:300]}")
        print(f"job {job} runs in the guest. guest-job status {job} tells how it is doing, guest-job log {job} what it printed")
        return
    shown(tool, args, *result)


def shown(tool, args, code, out, err, more):
    if args.json:
        json.dump({"exit": code, "out": plain(out[:args.max]), "err": plain(err[:args.max]), "cut": more or max(len(out), len(err)) > args.max}, sys.stdout)
        print()
        return
    show(tool, code, out, err, args.max, more)


def execute(args):
    guest = Guest()
    if not args.command:
        fail("what to run is missing")
    whom = account(guest, args)
    given = sys.stdin.buffer.read(WRITE) if args.stdin else None
    line = " ".join(args.command)
    job = secrets.token_hex(3) if args.job else None
    if whom is not None or job:
        if guest.windows():
            if args.powershell:
                script = f"{UTF8}{line}; if ($LASTEXITCODE) {{ exit $LASTEXITCODE }}"
                program, text = "powershell.exe", subprocess.list2cmdline([*POWERSHELL, "-EncodedCommand", base64.b64encode(script.encode("utf-16-le")).decode()])
            elif args.shell:
                # With /s cmd takes off the outer quotes and reads the rest as it is.
                program, text = "cmd.exe", f'cmd.exe /d /s /c "{line}"'
            else:
                program, text = args.command[0], subprocess.list2cmdline(args.command)
            argv = on_windows(program, text, whom, args, job=job)
        elif args.powershell:
            fail("only a Windows guest has PowerShell")
        else:
            argv = elsewhere(line if args.shell else shlex.join(args.command), whom, args, job=job)
        carried_out("exec", guest, args, argv, given, job)
        return
    if args.powershell:
        move = "Set-Location -LiteralPath $a[0]; " if args.cwd else ""
        result = guest.powershell(f"{move}{line}; if ($LASTEXITCODE) {{ exit $LASTEXITCODE }}", args.cwd, timeout=args.timeout)
    elif args.shell and guest.windows():
        # cmd reads its line from a variable, since no quoting survives the two programs it would pass through.
        move = "Set-Location -LiteralPath $a[0]; " if args.cwd else ""
        result = guest.powershell(f"{move}$env:VM_INSPECT_LINE = $a[1]; cmd.exe /d /c '%VM_INSPECT_LINE%'; exit $LASTEXITCODE", args.cwd, line, timeout=args.timeout)
    elif args.shell:
        result = guest.run(["/bin/sh", "-c", f'cd "$1" && {line}' if args.cwd else line, "sh", args.cwd or ""], given, args.timeout)
    elif args.cwd and guest.windows():
        result = guest.powershell("Set-Location -LiteralPath $a[0]; $rest = @($a | Select-Object -Skip 2); & $a[1] @rest; exit $LASTEXITCODE",
                                  args.cwd, *args.command, timeout=args.timeout)
    elif args.cwd:
        result = guest.run(["/bin/sh", "-c", 'cd "$1" && shift && exec "$@"', "sh", args.cwd, *args.command], given, args.timeout)
    else:
        result = guest.run(args.command, given, args.timeout)
    shown("exec", args, *result)


def found_python(guest, whom):
    if guest.windows():
        who = [] if whom is None else ["--user", whom] if whom else ["--desktop"]
        code, out, _, _ = helped(guest, lambda: guest.run([helper(), "find", *who, "python.exe", *PYTHONS]))
    else:
        code, out, _, _ = guest.run(["/bin/sh", "-c", "command -v python3 || command -v python"])
    found = plain(out).strip().splitlines()
    if code != 0 or not found:
        fail("no Python was found in the guest. Install one in it, or name the interpreter with --python")
    return found[0]


def python(args):
    guest = Guest()
    whom = account(guest, args)
    if args.stdin and args.script == "-":
        fail("standard input can be the script or what the script reads, not both")
    try:
        script = sys.stdin.buffer.read() if args.script == "-" else pathlib.Path(args.script).read_bytes()
    except OSError as e:
        fail(f"{args.script} cannot be read: {e.strerror}")
    given = sys.stdin.buffer.read(WRITE) if args.stdin else None
    job = secrets.token_hex(3) if args.job else None
    interpreter = args.python or found_python(guest, whom)
    name = f"vm-inspect-{secrets.token_hex(8)}.py"
    path = f"C:\\Windows\\Temp\\{name}" if guest.windows() else f"/tmp/{name}"
    guest.write(path, script)
    words = [interpreter, path, *args.arguments]
    if guest.windows():
        argv = on_windows(interpreter, subprocess.list2cmdline(words), whom, args, grant=[path], delete=[path], job=job)
    else:
        argv = elsewhere(shlex.join(words), whom, args, grant=[path], delete=[path], job=job)
    carried_out("py", guest, args, argv, given, job, leftover=path)


def job(args):
    guest = Guest()
    if args.action in ("log", "stop") and not args.id:
        fail(f"{args.action} takes the name of a job")
    if args.id and not JOB.fullmatch(args.id):
        fail("a job's name is six letters and digits, as guest-job status lists them")
    home, between = (f"{HOME}\\jobs", "\\") if guest.windows() else (JOBS, "/")
    if args.action == "log":
        said = plain(ending(guest, f"{home}{between}{args.id}.log", args.max))
        print("guest-job: what follows was written by the guest", file=sys.stderr)
        sys.stdout.write("".join(said.splitlines(keepends=True)[-args.tail:]))
        return
    windows, posix = {"status": STATUS, "stop": STOP, "clean": CLEAN}[args.action]
    code, out, err, _ = guest.script(windows, posix, home, args.id or "*")
    if args.action == "status" and args.id and code == 0 and not out.strip():
        fail("there is no job of that name")
    show("job", code, out, err, SHOWN)


def wait(args):
    if args.window is not None:
        if args.gone:
            fail("--gone goes with a process or a file")
        windows(argparse.Namespace(title=args.window, wait=args.timeout, user=None, json=False))
        return
    guest = Guest()
    what, value = ("process", args.process) if args.process is not None else ("file", args.file)
    if guest.windows():
        words = [helper(), "wait", f"--{what}", value, "--seconds", str(args.timeout)] + (["--gone"] if args.gone else [])
        code, _, err, _ = helped(guest, lambda: guest.run(words, timeout=args.timeout + 30))
    else:
        code, _, err, _ = guest.run(["/bin/sh", "-c", WAIT, "sh", what, value, "1" if args.gone else "0", str(args.timeout * 5)], timeout=args.timeout + 30)
    if code == 1:
        fail(f"{value} was still {'there' if args.gone else 'missing'} after {args.timeout} seconds")
    if code != 0:
        fail(plain(err).strip()[:300] or "the guest could not wait for it")
    print(f"{value} is {'gone' if args.gone else 'there'}")


def windows(args):
    guest = Guest()
    if not guest.windows():
        fail("only a Windows guest can be asked for its windows. Elsewhere the desktop's own tools tell, through guest-exec")
    exe = helper()
    asked = ["windows"] + (["--title", args.title, "--seconds", str(args.wait)] if args.title else [])
    whom = ["--user", args.user] if args.user else ["--desktop"]
    # The helper starts itself on the user's desktop, which is the only place windows can be seen from.
    argv = [exe, "run", *whom, "--grant", exe, exe, subprocess.list2cmdline([exe, *asked])]
    code, out, err, _ = helped(guest, lambda: guest.run(argv, timeout=args.wait + 30))
    rows = [line.split("\t", 8) for line in plain(out).splitlines()[:WINDOWS + 1]]
    number = re.compile(r"-?\d{1,12}")
    screen = next((row for row in rows if len(row) == 3 and row[0] == "screen" and all(number.fullmatch(n) for n in row[1:])), None)
    if code not in (0, 1) or screen is None:
        fail(plain(err).strip()[:300] or "the guest did not list its windows")
    found = [{"handle": int(row[0]), "pid": int(row[1]), "program": row[2], "x": int(row[3]), "y": int(row[4]), "width": int(row[5]), "height": int(row[6]),
              "state": row[7], "title": row[8]}
             for row in rows if len(row) == 9 and all(number.fullmatch(n) for n in row[:2] + row[3:7])]
    if args.json:
        json.dump({"screen": [int(screen[1]), int(screen[2])], "windows": found}, sys.stdout)
        print()
    else:
        print("guest-windows: what follows was written by the guest", file=sys.stderr)
        print(f"screen {screen[1]}x{screen[2]}")
        for window in found:
            print(f"{window['handle']:#x}  pid {window['pid']}  {window['program']}  {window['x']},{window['y']} {window['width']}x{window['height']}  "
                  f"{window['state']}  {window['title']}")
    if args.title and not found:
        fail(f"no window has {args.title} in its title")

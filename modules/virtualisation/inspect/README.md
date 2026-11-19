# vm-inspect

`vm-inspect` opens a running libvirt guest to the user who asks for it.
A session gives the guest's memory, QEMU's debug stub and pictures of its screen.
Opened with `--control`, it also takes keys and pointer events for the guest and reaches the agent that runs inside it.
A guest that is never opened is not changed by any of this.

## A session

```
vm-inspect [--gdb] [--control] DOMAIN -- COMMAND...
vm-inspect --join DOMAIN -- COMMAND...
```

Opening a guest asks for an administrator through pkexec.
The part that runs as root, `_inspect_helper.py`, takes one request a line and rebuilds every command from checked fields.
A guest is open to one session at a time.
`--join` runs another program in a session that is already open, with no second approval.
The session ends when its command ends, and everything it plugged into the guest leaves with it.

Only the domains listed in `my.virtualisation.inspect.domains` can be opened, and only when QEMU shares their memory.

What a session did to its guest is written to `~/.local/state/vm-inspect/DOMAIN.log`, one line a request.
The line holds what was sent, with PowerShell scripts and their values decoded, and whether it was done or refused.
The session writes it, so no tool can leave a line out.

## The guest tools

The tools are the package `my.virtualisation.inspect.guestTools`.
They are on no path by themselves.
What they print was written by the guest, so they belong in a sandbox around `vm-inspect`, which puts them on its own path.
`my.virtualisation.lab`, in `../lab`, gives `vm-lab`, a shell with these tools and the guest's memory.
Where the confine module is loaded, `vm-lab` runs in a sandbox with no network and none of the user's files but the folder it starts in.
On a system without confine it runs with no sandbox, says so, and has `lab-box` as its one barrier.
Each one explains itself with `--help`.
A module can build another tool on a session from `my.virtualisation.inspect.guestLibrary`, the Python these are made of, as `../lab/agent` does for `guest-mcp`.

| Tool | What it does | Needs `--control` |
|---|---|---|
| `guest-shot` | A picture of the screen as a PNG, from QEMU or from the frames Looking Glass shares, whole or a part with `--crop` | no |
| `guest-shot --window` | One window of a Windows guest, covered or minimized as it may be, whole or a part | yes |
| `guest-input` | Keys, text, pointer moves, clicks, the wheel and drags | yes |
| `guest-exec` | Runs a program, a shell line or a PowerShell script and passes on its exit status | yes |
| `guest-py` | Runs a Python script of this side with the Python the guest has | yes |
| `guest-job` | Follows what was started with `--job`: status, log, stop, clean | yes |
| `guest-wait` | Waits in the guest for a process, a file or a window | yes |
| `guest-windows` | Lists the windows of a Windows desktop with their place in screen pixels | yes |
| `guest-read`, `guest-ls`, `guest-stat`, `guest-hash`, `guest-grep`, `guest-find` | Files of the guest, searched and filtered in the guest | yes |
| `guest-push`, `guest-pull` | A file into or out of the guest, compared by SHA-256 on both sides | yes |
| `guest-status` | Agent, system, name, users, clock and free space | yes |
| `guest-agent` | One raw command for the agent, from a fixed list | yes |

## Two kinds of picture

The picture of the screen is taken from outside the guest.
Nothing in the guest decides what it shows.

The picture of one window is drawn by the guest, since only the guest can draw a window that is covered or minimized.
It is brought over as plain rows of pixels, and the PNG is written on this side.
A program in the guest can make such a picture show anything, so it tells what the guest wants seen.
A minimized window is shown for the moment without taking the keyboard, and minimized again.

## Who a program runs as

The agent starts programs as the system's own account.
In Windows that account lives in a session without a desktop, so it sees no windows and can send no input.

`guest-exec` and `guest-py` take these options:

- `--as-user` runs the program as the user who is logged in, in Windows on their desktop.
- `--user NAME` runs it as that account, which in Windows has to be logged in.
- `--elevated` gives it that user's administrator rights, in Windows.
- `--job` starts it and returns at once with a name for `guest-job`.

In Windows this is done by a helper, `_guest/helper.cs`.
The guest compiles it itself the first time it is needed, with the C# compiler every Windows carries, into the system account's own profile.
That takes about half a second, and happens again whenever the helper is missing.
The folder is one only the system account and administrators can write to.
A shared temporary folder would let any program in the guest put its own file there under the helper's name, to be run as the system.
The helper takes the logged in user's token, starts the program with that user's environment and passes the output through.
Elsewhere `su` does the same.

The guest's agent keeps every program it started until it is asked how that one ended, and finds a program by its number, which the guest soon gives to another.
A program nobody asked about would then answer for a later one with the same number.
So a job runs apart from the program the agent started, which ends as soon as the job has begun, and every program a tool stops is asked about afterwards.
A tool also takes an answer that a program ended only once the agent keeps no other program under that number.

`guest-py` looks for an interpreter in the guest and uses the one named with `--python` otherwise.
It installs nothing.
A guest that lacks something gets it through `guest-exec` and the guest's own package manager, or through `guest-push` and an installer.

## Files in and out

A file of 128 MiB or more travels as a disk.
The session plugs the file itself into the guest as a raw disk, read only for a push, and takes it out again afterwards.
There is no filesystem on it, so this side parses nothing the guest wrote.
Smaller files go through the agent in pieces.
`--disk` and `--stream` force one way.
The disk goes onto the guest's virtio SCSI controller when it has one, and onto USB otherwise.

Measured on a Windows guest: 1 GiB in 2.5 seconds by disk, of which 1.7 are setup, and 40 to 65 MB a second through the agent.

## What ends up in a guest

- Windows: the helper and the files of jobs in `C:\Windows\System32\config\systemprofile\AppData\Local\vm-inspect`.
  Scripts go to `C:\Windows\Temp\vm-inspect-*.py` and are removed when they have run.
- Elsewhere: the files of jobs in `/run/vm-inspect-jobs`, scripts in `/tmp/vm-inspect-*.py`.
- While a session with `--control` is open: a virtio serial port for the agent, and for the length of a large transfer one disk.

The agent itself has to be installed in the guest already.

## What a guest can do to this side

Everything a tool gets back was written by the guest and is treated as data.

- An answer is checked for its shape before anything is taken from it.
- Text is shown without the characters a terminal acts on.
- Output, files and listings have a size limit, and a tool says when it cut something off.
- The name of a file on this side is taken from what was asked for, never from what the guest says.
- A name the guest gives, such as who is logged in, goes into a command line as one quoted word.

`_tests/hostile_agent.py` plays a guest that answers as badly as it can and checks that every tool ends in plain words.

The text a guest prints can still try to talk a reader into something.
That is for the reader to resist, and the reason the tools belong in a sandbox.

## Limits

- The agent of a Windows guest cannot open a file that a program is writing.
  The tools that follow a running program's output read it through the helper, which can.
- `guest-windows`, `--elevated` and waiting for a window work in Windows only.
- In a Linux guest `--as-user` sets `XDG_RUNTIME_DIR` and nothing else of a desktop.
- A job in a Linux guest is a child of the agent's service and ends when that service is stopped.
- The USB way for a transfer's disk has not been tried.
- Text is typed on a US keyboard layout.

## Tests

```
nix build --no-link -L .#tests.inspect.vm-inspect
```

It opens nested guests and drives a small Linux one through every tool.
The machine it boots is the made up host of `core/_tests/system.nix`, with every shared module on it as a fork has them.
`_tests/fixture.nix` holds that machine and the small guest, for the test of a module that builds on a session: it gives its tools and its script, and boots the guest alone.
The Windows side has no test here and was tried by hand on a real guest.

"""Tools for the guest of an open vm-inspect session, started as guest-NAME with the name as the first argument."""
import argparse
import sys

import agent
import keys
import programs
import screen
from session import Refused, fail


def size(text):
    """A number of bytes, which may end in K, M or G."""
    scale = {"K": 2 ** 10, "M": 2 ** 20, "G": 2 ** 30}.get(text[-1:].upper(), 1)
    try:
        return int(text[:-1] if scale > 1 else text) * scale
    except ValueError:
        raise argparse.ArgumentTypeError("a number of bytes, which may end in K, M or G") from None


def running(parser):
    """How a program is run, which guest-exec and guest-py share."""
    parser.add_argument("--as-user", action="store_true", help="as the user who is logged in, and in Windows on their desktop. The agent's own account otherwise")
    parser.add_argument("--user", metavar="NAME", help="as this account, which in Windows has to be logged in")
    parser.add_argument("--elevated", action="store_true", help="with the administrator's rights of that user, in Windows")
    parser.add_argument("--job", action="store_true", help="start it and come back at once, guest-job tells how it goes")
    parser.add_argument("--cwd", help="the folder to run it in")
    parser.add_argument("--stdin", action="store_true", help="give it what this reads on standard input, up to 48 KiB")
    parser.add_argument("--timeout", type=int, default=60, help="seconds after which it is stopped, 60 by default")
    parser.add_argument("--max", type=size, default=agent.SHOWN, help="bytes of output to show, 1M by default")
    parser.add_argument("--json", action="store_true", help="print one JSON object with exit, out, err and cut")


def for_exec(parser):
    """Run a program in the guest, wait for it and print what it printed. Its exit status becomes this one's."""
    parser.add_argument("--shell", action="store_true", help="the words are one line for the guest's shell, cmd in Windows and sh elsewhere")
    parser.add_argument("--powershell", action="store_true", help="the words are a PowerShell script")
    running(parser)
    parser.add_argument("command", nargs=argparse.REMAINDER, help="the program and its arguments, or the line or script")


def for_py(parser):
    """Run a Python script of this side with the Python the guest has. Its exit status becomes this one's."""
    parser.add_argument("--python", metavar="PATH", help="the interpreter in the guest, which is looked for otherwise")
    running(parser)
    parser.add_argument("script", help="the script on this side, - for standard input")
    parser.add_argument("arguments", nargs=argparse.REMAINDER, help="what the script is given")


def for_job(parser):
    """Tell how what was started with --job is doing, show what one printed, stop one, or clear the finished away."""
    parser.add_argument("action", choices=["status", "log", "stop", "clean"])
    parser.add_argument("id", nargs="?", help="the job, as it was named when it started")
    parser.add_argument("--tail", type=int, default=40, metavar="LINES", help="lines of the log to show, the last 40 by default")
    parser.add_argument("--max", type=size, default=agent.SHOWN, help="bytes of the log to read at most, 1M by default")


def for_wait(parser):
    """Wait in the guest until a process runs, a file exists or a window is open. Its exit status is 1 when that took too long."""
    what = parser.add_mutually_exclusive_group(required=True)
    what.add_argument("--process", metavar="NAME")
    what.add_argument("--file", metavar="PATH")
    what.add_argument("--window", metavar="TEXT", help="a window with this in its title, in Windows")
    parser.add_argument("--gone", action="store_true", help="wait for the process or the file to be gone instead")
    parser.add_argument("--timeout", type=int, default=60, help="seconds to wait at most, 60 by default")


def for_windows(parser):
    """List the windows on the desktop of a Windows guest: where each is on the screen, in the screen's pixels, and whose it is."""
    parser.add_argument("--title", metavar="TEXT", help="only windows with this in their title")
    parser.add_argument("--wait", type=int, default=0, metavar="SECONDS", help="wait this long for a window with that title")
    parser.add_argument("--user", metavar="NAME", help="the desktop of this account, the one someone works at otherwise")
    parser.add_argument("--json", action="store_true")


def for_read(parser):
    """Print a file of the guest, or a part of it, as text."""
    parser.add_argument("path")
    parser.add_argument("--offset", type=size, default=0, help="where in the file to start")
    parser.add_argument("--max", type=size, default=agent.SHOWN, help="bytes to read at most, 1M by default")
    parser.add_argument("--head", type=int, metavar="LINES", help="only the first lines of what was read")
    parser.add_argument("--tail", type=int, metavar="LINES", help="the last lines of the file")
    parser.add_argument("--raw", action="store_true", help="the bytes as they are, for a pipe and not for a terminal")


def ways(parser):
    """A file of 128 MiB or more travels as a disk the guest has for that long, a smaller one through the agent."""
    parser.add_argument("--disk", action="store_true", help="by disk whatever the size")
    parser.add_argument("--stream", action="store_true", help="through the agent whatever the size")


def for_push(parser):
    """Copy a file into the guest and check that it arrived whole."""
    parser.add_argument("file", help="the file on this side")
    parser.add_argument("path", help="where it goes in the guest")
    ways(parser)


def for_pull(parser):
    """Copy a file out of the guest and check that it arrived whole. It lands in ./out when that folder exists."""
    parser.add_argument("path", help="the file in the guest")
    parser.add_argument("file", nargs="?", help="where it goes on this side")
    parser.add_argument("--max", type=size, default=agent.PULLED, help="the largest file to take, 256M by default")
    ways(parser)


def for_ls(parser):
    """List a folder of the guest."""
    parser.add_argument("path")
    parser.add_argument("--max", type=int, default=agent.LISTED, help="entries to list at most, 200 by default")


def for_stat(parser):
    """Show the size, the dates and the attributes of a file or folder of the guest."""
    parser.add_argument("path")


def for_hash(parser):
    """Print the SHA-256 of a file of the guest, worked out in the guest."""
    parser.add_argument("path")


def for_grep(parser):
    """Search a file or a folder of the guest for a pattern. The search runs in the guest and only its matches come back."""
    parser.add_argument("pattern")
    parser.add_argument("path")
    parser.add_argument("-F", "--fixed", action="store_true", help="the pattern is plain text")
    parser.add_argument("-i", "--ignore-case", action="store_true")
    parser.add_argument("-C", "--context", type=int, default=0, help="lines to show around each match")
    parser.add_argument("--max", type=int, default=agent.LISTED, help="matches to show at most, 200 by default")
    parser.add_argument("--timeout", type=int, default=120)


def for_find(parser):
    """Find files below a folder of the guest by name, where * stands for any part of it."""
    parser.add_argument("path")
    parser.add_argument("name")
    parser.add_argument("--max", type=int, default=agent.LISTED, help="files to list at most, 200 by default")
    parser.add_argument("--timeout", type=int, default=120)


def for_status(parser):
    """Say what the guest is: its agent, system, name, users, clock and disks."""
    parser.add_argument("--json", action="store_true")


AGENT_TOOLS = {
    "exec": (for_exec, programs.execute), "py": (for_py, programs.python), "job": (for_job, programs.job), "wait": (for_wait, programs.wait),
    "windows": (for_windows, programs.windows), "read": (for_read, agent.read), "push": (for_push, agent.push), "pull": (for_pull, agent.pull),
    "ls": (for_ls, agent.listing), "stat": (for_stat, agent.details), "hash": (for_hash, agent.digest), "grep": (for_grep, agent.search),
    "find": (for_find, agent.find), "status": (for_status, agent.status),
}


def main():
    tool = sys.argv[1] if len(sys.argv) > 1 else ""
    if tool == "shot":
        parser = argparse.ArgumentParser(prog="guest-shot",
                                         description="Save a picture of the guest's screen as a PNG and print its path and size.")
        parser.add_argument("file", nargs="?", help="where to save it, guest-shot-DATE-TIME.png in this folder by default")
        parser.add_argument("--source", default="auto", choices=["auto", "qemu", "frames"],
                            help="qemu for the screen QEMU draws, frames for what Looking Glass shares, auto for the first that there is")
        parser.add_argument("--window", metavar="TITLE", help="one window of a Windows guest instead of the screen, by a part of its title or by the 0x number "
                            "guest-windows gives it. The guest draws it, covered or minimized as it may be, so the session has to be opened with --control")
        parser.add_argument("--crop", nargs=4, type=int, metavar=("X", "Y", "WIDTH", "HEIGHT"), help="only this part, in pixels from the top left")
        try:
            screen.shot(parser.parse_args(sys.argv[2:]))
        except Refused as e:
            fail(str(e))
    elif tool == "input":
        parser = argparse.ArgumentParser(prog="guest-input",
                                         description="Send keys and pointer events to the guest. The session has to be opened with --control.")
        parser.add_argument("--hold", type=int, default=30, help="milliseconds a key or button stays down, and between steps")
        actions = parser.add_subparsers(dest="action", required=True)
        action = actions.add_parser("key", help="press keys together, as in ctrl+alt+delete, one chord after the other")
        action.add_argument("keys", nargs="+", metavar="CHORD")
        action = actions.add_parser("type", help="type text on a US keyboard, - reads it from standard input")
        action.add_argument("text")
        action = actions.add_parser("move", help="put the pointer at a place")
        action.add_argument("x", type=float)
        action.add_argument("y", type=float)
        action.add_argument("--of", metavar="WIDTHxHEIGHT", help="X and Y are pixels of a picture this size")
        action = actions.add_parser("nudge", help="move the pointer by an amount, for programs that read the mouse itself")
        action.add_argument("dx", type=int)
        action.add_argument("dy", type=int)
        action = actions.add_parser("click", help="click, at a place when --at is given")
        action.add_argument("--button", default="left", choices=["left", "middle", "right", "side", "extra"])
        action.add_argument("--at", nargs=2, type=float, metavar=("X", "Y"))
        action.add_argument("--of", metavar="WIDTHxHEIGHT")
        action.add_argument("--double", action="store_true")
        action = actions.add_parser("scroll", help="turn the wheel, up for a positive amount")
        action.add_argument("amount", type=int)
        action = actions.add_parser("drag", help="press at one place and let go at another")
        action.add_argument("x", type=float)
        action.add_argument("y", type=float)
        action.add_argument("to_x", type=float)
        action.add_argument("to_y", type=float)
        action.add_argument("--button", default="left", choices=["left", "middle", "right"])
        action.add_argument("--of", metavar="WIDTHxHEIGHT")
        keys.send_input(parser.parse_args(sys.argv[2:]))
    elif tool == "agent":
        parser = argparse.ArgumentParser(prog="guest-agent",
                                         description="Ask the agent in the guest one thing and print its answer. The session has to be opened with --control.")
        parser.add_argument("name", help="what to ask, such as ping, info, get-osinfo, exec or file-open")
        parser.add_argument("arguments", nargs="?", help="its arguments as one JSON object")
        agent.agent(parser.parse_args(sys.argv[2:]))
    elif tool in AGENT_TOOLS:
        build, run = AGENT_TOOLS[tool]
        parser = argparse.ArgumentParser(prog=f"guest-{tool}", description=build.__doc__,
                                         epilog="It works through the agent in the guest, so the session has to be opened with --control. "
                                                "What it prints was written by the guest.")
        build(parser)
        try:
            run(parser.parse_args(sys.argv[2:]))
        except Refused as e:
            fail(str(e))
    else:
        fail("this is started as guest-NAME, with NAME one of shot, input, agent, " + ", ".join(AGENT_TOOLS))


if __name__ == "__main__":
    main()

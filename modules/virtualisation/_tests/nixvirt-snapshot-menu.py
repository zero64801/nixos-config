"""Drives nixvirt-snapshot's menu on a pseudo terminal, against a stand-in virsh and a sudo that records its command.

The stand-in has five domains, in this order: daily (off, one snapshot), deep (off, snapshots a, b and the current c),
live (running, one snapshot), plain (off, no snapshot) and odd (paused).
"""
import os
import subprocess
import sys
from pathlib import Path

import pexpect

SUDO_LOG = Path(os.environ["SUDO_LOG"])


def run(keys):
    """Sends the keys one prompt at a time and returns what the screen showed and what sudo was given, if anything."""
    SUDO_LOG.unlink(missing_ok=True)
    child = pexpect.spawn("nixvirt-snapshot", encoding="utf-8", timeout=20)
    shown = ""
    for key in keys:
        child.expect([r"domain \(q quits\): ", "action: ", r"name \(Enter[^:]*\): ", r"snapshot \(Enter[^:]*\): ", "nixvirt-snapshot "])
        shown += child.before + child.after
        child.send(key)
    child.expect(pexpect.EOF)
    shown += child.before
    child.close()
    command = SUDO_LOG.read_text().strip() if SUDO_LOG.exists() else None
    return shown, command, child.exitstatus


def expect(keys, command, *texts):
    shown, ran, status = run(keys)
    assert ran == command, f"keys {keys!r} ran {ran!r}, not {command!r}\n{shown}"
    assert status == 0, f"keys {keys!r} ended with status {status}\n{shown}"
    for text in texts:
        assert text in shown, f"keys {keys!r} never showed {text!r}\n{shown}"
    return shown


expect(["1", "r"], "nixvirt-snapshot rotate daily safe0",
       "domain: daily (shut off)", "[safe0] /images/daily.safe0", "-> sudo nixvirt-snapshot rotate daily safe0")
expect(["1", "v"], "nixvirt-snapshot revert daily safe0")
expect(["1", "m"], "nixvirt-snapshot commit --to safe0 daily")
expect(["1", "d"], "nixvirt-snapshot delete daily safe0")

shown = expect(["2", "v", "3"], "nixvirt-snapshot revert deep a", "c (3 snapshots)", "Everything newer is discarded")
assert shown.index("1  c") < shown.index("2  b") < shown.index("3  a"), shown
expect(["2", "v", "\r"], "nixvirt-snapshot revert deep c")
expect(["2", "m", "2"], "nixvirt-snapshot commit --to b deep")
expect(["2", "r", "9", "2"], "nixvirt-snapshot rotate deep b")

expect(["3", "v", "r"], "nixvirt-snapshot rotate live safe0", "revert  needs the VM shut off")

expect(["4", "r", "v", "m", "d", "c", "first\r"], "nixvirt-snapshot create plain first", "rotate  no snapshot yet")
expect(["4", "c", "\r"], "nixvirt-snapshot create plain")

expect(["5", "c", "r", "b", "q"], None, "create  needs the VM running or shut off", "nothing was changed.")
expect(["7", "\r", "x", "\x1b"], None, "nothing was changed.")

expect(["1", "V", "--no-data\r"], "nixvirt-snapshot revert daily safe0 --no-data")
expect(["4", "C", "\r", "--mem\r"], "nixvirt-snapshot create plain --mem")
expect(["1", "R", "\r"], "nixvirt-snapshot rotate daily safe0")


def plain(*args):
    return subprocess.run(["nixvirt-snapshot", *args], check=False, stdin=subprocess.DEVNULL, capture_output=True, text=True)


no_terminal = plain()
assert no_terminal.returncode == 1 and "usage: nixvirt-snapshot" in no_terminal.stderr, no_terminal
listed = plain("list", "deep")
assert listed.returncode == 0 and "snapshots: 3  (current: c)" in listed.stdout, listed
refused = plain("revert", "daily")
assert refused.returncode == 1 and "run as root: sudo nixvirt-snapshot revert daily" in refused.stderr, refused

# The stand-in virsh refuses anything but the read only connection, so getting here means no read asked for more.
calls = Path(os.environ["VIRSH_LOG"]).read_text().splitlines()
assert calls and all(call.startswith("-r ") for call in calls), calls
print(f"{len(calls)} virsh calls, all read only", file=sys.stderr)

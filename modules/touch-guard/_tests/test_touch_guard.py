import contextlib
import io
import json
import os
import socket
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

sys.path.insert(0, sys.argv.pop(1))
import _daemon as d
import _notifier as n
import _pam as p

# Read from a YubiKey 5's FIDO interface and from its keyboard (OTP) interface on Quanta.
YUBIKEY_FIDO = bytes.fromhex("06d0f10901a1010920150026ff007508954081020921150026ff00750895409102c0")
YUBIKEY_OTP_KEYBOARD = bytes.fromhex("05010906a101050719e029e7150025017501950881029501750881019505750105081901290591029501750391019506750815002565050719002965")
NOTIFIER = ["/nix/store/x-python/bin/python3", "-I", "/nix/store/x-notifier.py", "--busctl", "/nix/store/x-systemd/bin/busctl"]


def frame(cmd, *data, cid=1):
    return bytes([0, 0, 0, cid, cmd, 0, len(data)] + list(data)).ljust(64, b"\0")


UPNEEDED = frame(d.CTAPHID_KEEPALIVE, d.STATUS_UPNEEDED)
TOUCHED = frame(d.CTAPHID_CBOR, 0x00, 0xA1)


class Proc:
    """A fake /proc tree whose processes may hold a fake device open."""

    MOUNT, OTHER_FS = "30", "31"

    def __init__(self, root):
        self.root = os.path.join(root, "proc")
        self.device = os.path.join(root, "hidraw16")
        os.makedirs(self.root)
        open(self.device, "w").close()
        st = os.stat(self.device)
        self.ino = st.st_ino
        self.mountinfo = (f"{self.MOUNT} 1 {os.major(st.st_dev)}:{os.minor(st.st_dev)} / {root} rw - tmpfs tmpfs rw\n"
                          f"{self.OTHER_FS} 1 999:999 / /fuse rw - fuse fuse rw\n")
        self.add(1, 0, ["systemd"], "/nix/store/x-systemd/lib/systemd/systemd", uid=0)

    def add(self, pid, ppid, cmdline, exe, uid=1000, euid=None, cwd="/home/dx", stdin="/dev/pts/0", fds=None,
            environ=("HOME=/home/dx",), tracer=0, ns=("mnt:[1]", "user:[2]"), start=100):
        """fds maps fd numbers to (link target, mount id, inode) as the kernel would report them."""
        base = os.path.join(self.root, str(pid))
        os.makedirs(os.path.join(base, "fd"))
        os.makedirs(os.path.join(base, "fdinfo"))
        os.makedirs(os.path.join(base, "ns"))
        euid = uid if euid is None else euid
        files = {
            "status": f"Name:\tx\nPPid:\t{ppid}\nTracerPid:\t{tracer}\nUid:\t{uid}\t{euid}\t{euid}\t{euid}\n",
            "comm": os.path.basename(exe)[:15] + "\n",
            "cmdline": "\0".join(cmdline) + "\0",
            "environ": "".join(e + "\0" for e in environ),
            "stat": f"{pid} (a b) S {ppid} " + " ".join(["0"] * 17) + f" {start} 0\n",
            "mountinfo": self.mountinfo,
        }
        for name, text in files.items():
            with open(os.path.join(base, name), "w") as f:
                f.write(text)
        os.symlink(exe, os.path.join(base, "exe"))
        os.symlink(cwd, os.path.join(base, "cwd"))
        for link in ns:
            os.symlink(link, os.path.join(base, "ns", link.split(":")[0]))
        for fd, (target, mnt, ino) in {0: (stdin, self.OTHER_FS, 1), **(fds or {})}.items():
            os.symlink(target, os.path.join(base, "fd", str(fd)))
            with open(os.path.join(base, "fdinfo", str(fd)), "w") as f:
                f.write(f"pos:\t0\nflags:\t02\nmnt_id:\t{mnt}\nino:\t{ino}\n")

    def key(self):
        return {5: (self.device, self.MOUNT, self.ino)}

    def sudo(self, pid, ppid, *command):
        """The real sudo: setuid, so it runs as root for the user who started it."""
        self.add(pid, ppid, ["sudo", *command], "/nix/store/x-sudo/bin/sudo", euid=0, fds=self.key())

    def report(self, polkit=None, context=None):
        return d.report_for(self.device, self.root, set(), polkit, context)


class Descriptors(unittest.TestCase):
    def test_fido_interface(self):
        self.assertTrue(d.is_fido_descriptor(YUBIKEY_FIDO))

    def test_keyboard_interface(self):
        self.assertFalse(d.is_fido_descriptor(YUBIKEY_OTP_KEYBOARD))

    def test_cut_mid_item(self):
        self.assertFalse(d.is_fido_descriptor(YUBIKEY_FIDO[:2]), "a usage page item missing its second byte must not match")
        self.assertFalse(d.is_fido_descriptor(b"\xfe"), "a lone long-item prefix must not crash")


class Waits(unittest.TestCase):
    def test_frames(self):
        self.assertEqual(d.frame_kind(UPNEEDED), "wait")
        self.assertIsNone(d.frame_kind(frame(d.CTAPHID_KEEPALIVE, 0x01)), "a processing keepalive changes nothing")
        self.assertEqual(d.frame_kind(frame(d.CTAPHID_MSG, 0x69, 0x85)), "wait")
        self.assertEqual(d.frame_kind(frame(d.CTAPHID_MSG, 0x90, 0x00)), "reply")
        self.assertEqual(d.frame_kind(TOUCHED), "reply")
        self.assertIsNone(d.frame_kind(frame(0x00, 0x01)), "continuation frames change nothing")
        self.assertIsNone(d.frame_kind(b"\0" * 5))

    def test_wait_ends_when_keepalives_stop(self):
        t = d.WaitTracker()
        self.assertTrue(t.feed(UPNEEDED, 0.0))
        self.assertFalse(t.feed(UPNEEDED, 0.1), "a continuing wait must not start again")
        self.assertIsNone(t.end(1.9))
        self.assertEqual(t.end(2.2), "keepalives stopped")
        self.assertIsNone(t.end(5.0), "an ended wait ends once")

    def test_reply_ends_wait_with_outcome(self):
        t = d.WaitTracker()
        t.feed(UPNEEDED, 3.0)
        t.feed(TOUCHED, 3.1)
        self.assertIsNone(t.end(3.25))
        self.assertEqual(t.end(3.35), "touched")
        t.feed(UPNEEDED, 4.0)
        t.feed(frame(d.CTAPHID_CBOR, 0x27), 4.1)
        self.assertEqual(t.end(4.4), "not touched", "how a YubiKey ends a wait nobody touched")

    def test_new_channel_starts_new_wait(self):
        t = d.WaitTracker()
        self.assertTrue(t.feed(UPNEEDED, 10.0))
        self.assertTrue(t.feed(frame(d.CTAPHID_KEEPALIVE, d.STATUS_UPNEEDED, cid=2), 10.1),
                        "another channel waiting is another requester")

    def test_other_channels_replies_are_ignored(self):
        t = d.WaitTracker()
        t.feed(UPNEEDED, 20.0)
        t.feed(frame(d.CTAPHID_ERROR, 0x06, cid=2), 20.1)
        self.assertIsNone(t.end(20.5), "a busy error sent to another channel must not end this wait")

    def test_same_channel_after_reply_starts_again(self):
        t = d.WaitTracker()
        t.feed(UPNEEDED, 30.0)
        t.feed(TOUCHED, 30.1)
        self.assertTrue(t.feed(UPNEEDED, 30.15), "a second request right after a touch needs its own scan")


class Sudo(unittest.TestCase):
    def test_options(self):
        self.assertEqual(d.describe_sudo(["sudo", "-Eu", "dx", "--", "id"]), ("sudo (runs as dx)", ["id"]))
        self.assertEqual(d.describe_sudo(["sudo", "--user=dx", "id", "-u"]), ("sudo (runs as dx)", ["id -u"]))
        self.assertEqual(d.describe_sudo(["sudo", "-i"])[1], ["opens a root shell"])
        self.assertEqual(d.describe_sudo(["sudo", "-e", "/etc/hosts"])[1], ["edit as root: /etc/hosts"])
        self.assertTrue(d.describe_sudo(["sudo", "-v"])[1][0].startswith("sudo -v: checks your login"))

    def test_env_values_and_store_hashes_are_left_out(self):
        system = "/nix/store/" + "a" * 32 + "-nixos-system-Quanta-26.11/bin/switch-to-configuration"
        _, lines = d.describe_sudo(["sudo", "env", "USER=dx", "PATH=/nix/store/x/bin:/run/wrappers/bin", system, "test"])
        self.assertEqual(lines, ["NixOS rebuild: switch-to-configuration test (nixos-system-Quanta-26.11)",
                                 "/nix/store/…-nixos-system-Quanta-26.11/bin/switch-to-configuration test (env sets USER, PATH)"])
        self.assertEqual(d.describe_sudo(["sudo", "env", "-u", "HOME", "LD_PRELOAD=/tmp/x.so", "id"])[1],
                         ["id (env sets LD_PRELOAD)"])
        self.assertEqual(d.describe_sudo(["sudo", "env"])[1], ["env"])

    def test_rebuild_targets(self):
        system = "/nix/store/" + "b" * 32 + "-nixos-system-Quanta-26.11"
        self.assertEqual(d.rebuild_target([system + "/bin/switch-to-configuration", "boot"]), (system, "boot"))
        self.assertEqual(d.rebuild_target(["nix", "build", "--no-link", "--profile", d.SYSTEM_PROFILE, system]),
                         (system, d.PROFILE_ACTION), "how nh sets the profile")
        self.assertEqual(d.rebuild_target(["nix-env", "-p", d.SYSTEM_PROFILE, "--set", system]),
                         (system, d.PROFILE_ACTION), "how nixos-rebuild sets the profile")
        self.assertEqual(d.rebuild_target(["/nix/store/x-nixos-activate/bin/nixos-activate", system]), (system, "switch"))
        self.assertEqual(d.rebuild_note(["/nix/store/x-nixos-activate/bin/nixos-activate", system, "boot"]),
                         "NixOS rebuild: boot (nixos-system-Quanta-26.11)")
        self.assertIsNone(d.rebuild_target(["nix", "build", system]), "building alone activates nothing")


class Requesters(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.p = Proc(tmp.name)
        self.p.add(900, 1, ["konsole"], "/nix/store/x-konsole/bin/konsole", stdin="/dev/null")
        self.p.add(901, 900, ["fish"], "/nix/store/x-fish/bin/fish", cwd="/home/dx/nixos")

    def test_rebuild_typed_in_a_terminal(self):
        self.p.add(950, 901, ["nh", "os", "switch"], "/nix/store/x-nh/bin/nh")
        self.p.sudo(951, 950, "-E", "/nix/store/abc-nixos-system-Quanta-26.11/bin/switch-to-configuration", "test")
        r = self.p.report()
        self.assertEqual(r["warnings"], [])
        (q,) = r["requesters"]
        self.assertEqual(q["title"], "sudo (runs as root)")
        self.assertEqual(q["lines"][0], "NixOS rebuild: switch-to-configuration test (nixos-system-Quanta-26.11)")
        self.assertEqual(q["user"], d.user_name(1000), "sudo's real uid is the user who ran it")
        self.assertEqual(q["warnings"], [])
        self.assertEqual(q["holder"], 951)
        self.assertTrue(q["chain"].startswith("nh ← fish ← konsole"), q["chain"])
        self.assertIn("sudo (runs as root)", d.summary_line(r))

    def test_rebuild_diff_goes_after_the_note(self):
        system = "/nix/store/" + "c" * 32 + "-nixos-system-Quanta-26.11"
        self.p.sudo(952, 901, "/nix/store/x-nixos-activate/bin/nixos-activate", system)
        asked = []

        def diff(path):
            asked.append(path)
            return ["system units: +evil.service"], ["changes root access config: sudoers"]

        context = types.SimpleNamespace(diff=diff, transient=lambda pid: None)
        (q,) = self.p.report(context=context)["requesters"]
        self.assertEqual(asked, [system])
        self.assertEqual(q["lines"][:2], ["NixOS rebuild: switch (nixos-system-Quanta-26.11)", "system units: +evil.service"])
        self.assertEqual(q["warnings"], ["changes root access config: sudoers"])

    def test_passwd(self):
        self.p.add(960, 901, ["passwd", "dx"], "/nix/store/x-shadow/bin/passwd", euid=0, fds=self.p.key())
        (q,) = self.p.report()["requesters"]
        self.assertEqual((q["title"], q["lines"], q["warnings"]), ("passwd (runs as root)", ["passwd dx"], []))

    def test_foreign_program_from_direnv(self):
        self.p.add(970, 901, ["direnv", "export", "fish"], "/nix/store/x-direnv/bin/direnv", cwd="/home/dx/Projects/x")
        self.p.add(971, 970, ["bash", "--noprofile", "--norc", "-c", "eval stdlib"], "/nix/store/x-bash/bin/bash",
                   stdin="pipe:[7]")
        self.p.add(972, 971, ["/home/dx/Downloads/tool", "--quiet"], "/home/dx/Downloads/tool", fds=self.p.key())
        (q,) = self.p.report()["requesters"]
        self.assertEqual(q["title"], "tool")
        self.assertEqual(q["warnings"], ["not from your system: /home/dx/Downloads/tool",
                                         "started by direnv, from the .envrc in /home/dx/Projects/x"])

    def test_piped_script(self):
        self.p.add(1000, 901, ["bash"], "/nix/store/x-bash/bin/bash", stdin="pipe:[1234]")
        self.p.sudo(1001, 1000, "true")
        (q,) = self.p.report()["requesters"]
        self.assertEqual(q["warnings"], ["started by bash reading piped commands"], "curl | bash must not pass for a shell")

    def test_script_in_a_project(self):
        self.p.add(1010, 901, ["bash", "./install.sh"], "/nix/store/x-bash/bin/bash", cwd="/home/dx/Projects/x")
        self.p.sudo(1011, 1010, "cp", "x", "/etc")
        (q,) = self.p.report()["requesters"]
        self.assertEqual(q["warnings"], ["started by /home/dx/Projects/x/install.sh"])
        self.assertTrue(q["chain"].startswith("bash install.sh ← fish"), q["chain"])

    def test_inline_shell_under_a_store_script(self):
        self.p.add(1200, 901, ["node", "/nix/store/x-agent/cli.js"], "/nix/store/x-node/bin/node")
        self.p.add(1201, 1200, ["bash", "-c", "script -q -c 'sudo true' /dev/null"], "/nix/store/x-bash/bin/bash",
                   stdin="pipe:[9]")
        self.p.add(1202, 1201, ["script", "-q", "-c", "sudo true", "/dev/null"], "/nix/store/x-util-linux/bin/script")
        self.p.sudo(1203, 1202, "true")
        (q,) = self.p.report()["requesters"]
        (warning,) = q["warnings"]
        self.assertTrue(warning.startswith("started by bash -c "), warning)

    def test_vscode_terminal_is_a_terminal(self):
        self.p.add(1100, 1, ["/nix/store/x-vscode/lib/vscode/code"], "/nix/store/x-vscode/lib/vscode/code")
        self.p.add(1101, 1100, ["/run/current-system/sw/bin/fish", "--init-command", 'source "/nix/store/x/shellIntegration.fish"'],
                   "/nix/store/x-fish/bin/fish", stdin="/dev/pts/3")
        self.p.sudo(1102, 1101, "true")
        (q,) = self.p.report()["requesters"]
        self.assertEqual(q["warnings"], [])

    def test_sudo_from_an_app(self):
        self.p.add(1100, 1, ["/nix/store/x-vscode/lib/vscode/code"], "/nix/store/x-vscode/lib/vscode/code")
        self.p.sudo(1103, 1100, "true")
        (q,) = self.p.report()["requesters"]
        self.assertEqual(q["warnings"], ["started by code, not from a terminal"])

    def test_two_requesters(self):
        self.p.sudo(951, 901, "true")
        self.p.add(980, 1, ["/tmp/x"], "/tmp/x", fds=self.p.key())
        r = self.p.report()
        self.assertEqual(len(r["requesters"]), 2)
        self.assertIn("2 requests at once, don't touch", r["warnings"])

    def test_child_of_a_holder_is_the_same_request(self):
        self.p.sudo(951, 901, "true")
        self.p.add(952, 951, ["true"], "/nix/store/x-coreutils/bin/true", fds=self.p.key())
        self.assertEqual(len(self.p.report()["requesters"]), 1)

    def test_git_signing_through_ssh_sk_helper(self):
        self.p.add(990, 901, ["git", "commit", "-m", "fix"], "/nix/store/x-git/bin/git")
        self.p.add(991, 990, ["ssh-keygen", "-Y", "sign", "-n", "git", "-f", "/home/dx/.ssh/github_yk.pub",
                              "/tmp/.git_signing_buffer_tmpX"], "/nix/store/x-openssh/bin/ssh-keygen")
        self.p.add(992, 991, ["/nix/store/x-openssh/libexec/ssh-sk-helper"], "/nix/store/x-openssh/libexec/ssh-sk-helper",
                   fds=self.p.key())
        (q,) = self.p.report()["requesters"]
        self.assertEqual((q["title"], q["lines"], q["pid"]), ("git signing", ["key github_yk.pub", "git commit -m fix"], 991))
        self.assertTrue(q["chain"].startswith("git ← fish"), q["chain"])
        self.assertEqual(q["warnings"], [])

    def test_ssh_login(self):
        self.p.add(993, 901, ["ssh", "host"], "/nix/store/x-openssh/bin/ssh")
        self.p.add(994, 993, ["ssh-sk-helper"], "/nix/store/x-openssh/libexec/ssh-sk-helper", fds=self.p.key())
        (q,) = self.p.report()["requesters"]
        self.assertEqual((q["title"], q["lines"]), ("SSH login", ["ssh host"]))

    def test_wrapped_browser(self):
        self.p.add(995, 1, ["zen-beta"], "/nix/store/x-zen/bin/.zen-beta-wrapped", fds=self.p.key())
        (q,) = self.p.report()["requesters"]
        self.assertEqual(q["title"], "browser login or passkey")

    def test_polkit_names_its_subject(self):
        self.p.add(996, 901, ["bash", "/home/dx/x/evil.sh"], "/nix/store/x-bash/bin/bash")
        self.p.add(997, 1, ["/nix/store/x-polkit/lib/polkit-1/polkit-agent-helper-1"],
                   "/nix/store/x-polkit/lib/polkit-1/polkit-agent-helper-1", uid=0, fds=self.p.key())
        polkit = {"action": "org.freedesktop.policykit.exec", "message": "Run a program as root",
                  "details": {"program": "/nix/store/x-scx/bin/scx-switch", "command_line": "scx-switch apply scx_chaos",
                              "polkit.subject-pid": "996", "polkit.caller-pid": "998"}}
        (q,) = self.p.report(polkit)["requesters"]
        self.assertEqual(q["title"], "admin rights (polkit)")
        self.assertEqual(q["lines"], ["Run a program as root (org.freedesktop.policykit.exec)", "scx-switch apply scx_chaos"])
        self.assertEqual(q["pid"], 996)
        self.assertEqual(q["holder"], 997)
        self.assertTrue(q["chain"].startswith("bash evil.sh ← fish"), q["chain"])
        self.assertEqual(q["warnings"], ["started by /home/dx/x/evil.sh"])

    def test_run0_from_a_sandbox_shows_the_unit_command(self):
        system = "/nix/store/" + "d" * 32 + "-nixos-system-Quanta-26.11"
        self.p.add(1400, 1, ["/nix/store/x-vscode/lib/vscode/code"], "/nix/store/x-vscode/lib/vscode/code")
        self.p.add(1401, 1400, ["/nix/store/x-xdg-dbus-proxy/bin/xdg-dbus-proxy", "--fd=3", "unix:path=/run/user/1000/bus",
                                "/run/user/1000/confine/com.visualstudio.code.4242/session-bus", "--filter"],
                   "/nix/store/x-xdg-dbus-proxy/bin/xdg-dbus-proxy")
        self.p.add(1402, 1, ["polkit-agent-helper-1"], "/nix/store/x-polkit/lib/polkit-1/polkit-agent-helper-1",
                   uid=0, fds=self.p.key())
        polkit = {"action": d.MANAGE_UNITS, "message": "Authentication is required to manage system services",
                  "details": {"polkit.subject-pid": "1401"}}
        unit = {"name": "run-u7.service", "argv": ["/nix/store/x-nixos-activate/bin/nixos-activate", system, "switch"],
                "user": "", "description": "[run0] nixos-activate", "pid": 1401, "time": 0}
        context = types.SimpleNamespace(diff=lambda path: (["nothing that runs as root changes"], []),
                                        transient=lambda pid: unit if pid == 1401 else None)
        (q,) = self.p.report(polkit, context)["requesters"]
        self.assertEqual(q["title"], "run0 (runs as root)")
        self.assertEqual(q["lines"], ["NixOS rebuild: switch (nixos-system-Quanta-26.11)", "nothing that runs as root changes",
                                      "/nix/store/x-nixos-activate/bin/nixos-activate /nix/store/…-nixos-system-Quanta-26.11 switch",
                                      "asked from inside the com.visualstudio.code sandbox"])

    def test_polkit_details_without_command(self):
        polkit = {"action": "org.freedesktop.systemd1.manage-units", "message": "",
                  "details": {"unit": "foo.service", "verb": "start", "polkit.message": "x"}}
        self.assertEqual(d.polkit_lines(polkit), ["org.freedesktop.systemd1.manage-units (org.freedesktop.systemd1.manage-units)",
                                                  "unit=foo.service, verb=start"])

    def test_polkit_without_monitor(self):
        self.p.add(997, 1, ["polkit-agent-helper-1"], "/nix/store/x-polkit/lib/polkit-1/polkit-agent-helper-1",
                   uid=0, fds=self.p.key())
        (q,) = self.p.report()["requesters"]
        self.assertEqual(q["lines"], ["action unknown, read the details in the KDE dialog"])

    def test_store_built_sudo_is_an_impostor(self):
        self.p.add(1300, 901, ["sudo", "nixos-rebuild", "switch"], "/nix/store/x-evil/bin/sudo", fds=self.p.key())
        (q,) = self.p.report()["requesters"]
        self.assertEqual((q["title"], q["lines"]), ("sudo", ["sudo nixos-rebuild switch"]))
        self.assertEqual(q["warnings"], ["calls itself sudo but does not run as root, so it is not the real one"])

    def test_fake_polkit_helper_gets_no_polkit_details(self):
        self.p.add(1301, 901, ["polkit-agent-helper-1"], "/nix/store/x-evil/bin/polkit-agent-helper-1", fds=self.p.key())
        polkit = {"action": "a.b", "message": "Looks legit", "details": {"polkit.subject-pid": "901"}}
        (q,) = self.p.report(polkit)["requesters"]
        self.assertEqual((q["title"], q["pid"]), ("polkit-agent-helper-1", 1301))
        self.assertEqual(q["warnings"], ["calls itself polkit-agent-helper-1 but does not run as root, so it is not the real one"])

    def test_nobody(self):
        self.assertIn("no program has the key open, don't touch unless you just started something", self.p.report()["warnings"])

    def test_same_inode_on_another_filesystem_is_not_the_key(self):
        self.p.add(985, 1, ["decoy"], "/nix/store/x-decoy/bin/decoy",
                   fds={6: ("/fuse/hidraw16", Proc.OTHER_FS, self.p.ino)})
        self.assertEqual(self.p.report()["requesters"], [])

    def test_unlisted_mount_still_counts(self):
        self.p.add(986, 1, ["holder"], "/nix/store/x-holder/bin/holder", fds={7: ("/gone/hidraw16", "77", self.p.ino)})
        self.assertEqual([q["pid"] for q in self.p.report()["requesters"]], [986])


class Polkit(unittest.TestCase):
    @staticmethod
    def call(member, *data):
        return {"interface": "org.freedesktop.PolicyKit1.AuthenticationAgent", "member": member,
                "payload": {"type": "", "data": list(data)}}

    def test_begin_cancel_and_latest(self):
        w = d.PolkitWatcher()
        w.handle(self.call("BeginAuthentication", "a.one", "One", "", {"polkit.subject-pid": "5"}, "cookie-1", []))
        w.handle(self.call("BeginAuthentication", "a.two", "Two", "", {}, "cookie-2", []))
        self.assertEqual(w.latest()["action"], "a.two")
        w.handle(self.call("CancelAuthentication", "cookie-2"))
        self.assertEqual(w.latest()["details"], {"polkit.subject-pid": "5"})
        w.handle(self.call("CancelAuthentication", "cookie-1"))
        self.assertIsNone(w.latest())
        self.assertIsNone(w.recent(3, 0.1), "nothing pending means nothing to wait for")

    def test_transient_unit_from_the_bus(self):
        # The shape busctl monitor --json=short prints for a StartTransientUnit call.
        message = {"interface": "org.freedesktop.systemd1.Manager", "member": "StartTransientUnit", "sender": ":1.268",
                   "payload": {"type": "ssa(sv)a(sa(sv))", "data": ["run-u9.service", "fail", [
                       ["Description", {"type": "s", "data": "[run0] probe"}],
                       ["User", {"type": "s", "data": "root"}],
                       ["ExecStart", {"type": "a(sasb)", "data": [["/run/current-system/sw/bin/true",
                                                                   ["/run/current-system/sw/bin/true", "a", "b c"], False]]}]],
                       []]}}
        w = d.PolkitWatcher(pid_of=lambda name: 4321 if name == ":1.268" else None)
        w.handle(message)
        unit = w.transient(4321)
        self.assertEqual((unit["argv"], unit["user"]), (["/run/current-system/sw/bin/true", "a", "b c"], "root"))
        self.assertEqual(d.describe_unit(unit), ("run0 (runs as root)", ["/run/current-system/sw/bin/true a 'b c'"]))
        self.assertIsNone(w.transient(1), "a unit belongs to the process that asked for it")


class Notifier(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.p = Proc(tmp.name)
        self.real = os.path.realpath(NOTIFIER[0])

    def check(self, **kwargs):
        options = {"exe": NOTIFIER[0], "cmdline": NOTIFIER, **kwargs}
        self.p.add(2000, 1500, options.pop("cmdline"), options.pop("exe"), **options)
        return d.notifier_problem(2000, 1000, NOTIFIER, self.p.root)

    def test_genuine(self):
        self.assertIsNone(self.check(exe=self.real))

    def test_other_program(self):
        self.assertEqual(self.check(exe="/home/dx/.local/bin/python3"), "it runs another program")

    def test_other_arguments(self):
        self.assertEqual(self.check(exe=self.real, cmdline=NOTIFIER[:3] + ["--busctl", "/home/dx/busctl"]),
                         "it was started with other arguments")

    def test_preloaded_library(self):
        self.assertEqual(self.check(exe=self.real, environ=("HOME=/home/dx", "LD_PRELOAD=/tmp/x.so")),
                         "its environment sets LD_PRELOAD")

    def test_traced(self):
        self.assertEqual(self.check(exe=self.real, tracer=1234), "another process traces it")

    def test_own_mount_namespace(self):
        self.assertEqual(self.check(exe=self.real, ns=("mnt:[9]", "user:[2]")), "it runs in its own mnt namespace")

    def test_other_user(self):
        self.assertEqual(self.check(exe=self.real, uid=1001), "it runs as another user")

    def test_gone(self):
        self.assertEqual(d.notifier_problem(4040, 1000, NOTIFIER, self.p.root), "it is gone")


class Socket(unittest.TestCase):
    def connect(self, allowed_uid, notifier=None, proc_root="/proc"):
        tmp = tempfile.mkdtemp()
        b = d.Broadcaster(os.path.join(tmp, "events.sock"), allowed_uid, notifier, proc_root)
        b.active[7] = {"event": "waiting", "id": 7}
        threading.Thread(target=b.serve, daemon=True).start()
        for _ in range(50):
            if os.path.exists(b.path):
                break
            time.sleep(0.02)
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(c.close)
        c.connect(b.path)
        c.settimeout(2)
        return b, c

    def wait_for_client(self, b):
        for _ in range(50):
            if b.clients:
                return
            time.sleep(0.02)

    def test_owner_gets_current_and_new_events(self):
        b, c = self.connect(os.getuid())
        stream = c.makefile("r")
        self.assertEqual(json.loads(stream.readline())["id"], 7, "a reconnecting notifier sees the open wait")
        self.wait_for_client(b)
        b.publish({"event": "done", "id": 7})
        self.assertEqual(json.loads(stream.readline())["event"], "done")

    def test_other_user_is_refused(self):
        _, c = self.connect(os.getuid() + 1)
        self.assertEqual(c.recv(64), b"", "the daemon must close connections from other users")

    def test_unexpected_program_is_refused(self):
        _, c = self.connect(os.getuid(), NOTIFIER)
        self.assertEqual(c.recv(64), b"", "a program that is not the system's notifier must not count as one")

    def test_answers_are_awaited(self):
        b, c = self.connect(os.getuid())
        self.wait_for_client(b)
        self.assertTrue(b.wait_for_notifier(0.1))
        self.assertFalse(b.wait_shown(7, 0.1), "no answer yet")
        c.sendall(b'{"event": "shown", "id": 7}\n{"event": "failed", "id": 8}\n')
        self.assertTrue(b.wait_shown(7, 2))
        self.assertFalse(b.wait_shown(8, 2), "a notification that failed counts as not shown")

    def test_no_notifier(self):
        b = d.Broadcaster("/nonexistent", os.getuid())
        start = time.monotonic()
        self.assertFalse(b.wait_for_notifier(0.2))
        self.assertGreaterEqual(time.monotonic() - start, 0.2, "a notifier that is restarting gets the whole wait")

    def test_stalled_client_is_dropped(self):
        b, _ = self.connect(os.getuid())
        self.wait_for_client(b)
        start = time.monotonic()
        for i in range(64):
            b.publish({"event": "waiting", "id": 100 + i, "pad": "x" * 65536})
        self.assertLess(time.monotonic() - start, 2, "publishing must never wait on a client")
        self.assertEqual(b.clients, [])


class FakeBroadcaster:
    def __init__(self, connected=True, shows=True):
        self.connected, self.shows, self.published = connected, shows, []

    def wait_for_notifier(self, timeout):
        return self.connected

    def publish(self, event):
        self.published.append(event)

    def wait_shown(self, event_id, timeout):
        return self.shows


class Pam(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.p = Proc(tmp.name)
        self.p.add(900, 1, ["konsole"], "/nix/store/x-konsole/bin/konsole", stdin="/dev/null")
        self.p.add(901, 900, ["fish"], "/nix/store/x-fish/bin/fish")
        self.p.sudo(950, 901, "true")
        self.ids = iter(range(50, 60))

    def guard(self, broadcaster):
        polkit = d.PolkitWatcher()
        return d.Guard(broadcaster, polkit, None, lambda: next(self.ids), self.p.root)

    def request(self, tty="/dev/pts/1", pid=950):
        return d.pam_request({"pid": pid, "service": "sudo", "user": "dx", "ruser": "", "tty": tty, "rhost": ""})

    def test_shown_request_goes_ahead(self):
        b = FakeBroadcaster()
        g = self.guard(b)
        allow, message = g.decide(self.request())
        self.assertTrue(allow)
        self.assertTrue(message.startswith("touch-guard: sudo (runs as root)\n  true"), "dialogs show the description")
        (event,) = b.published
        self.assertEqual((event["event"], event["id"], event["requesters"][0]["lines"]), ("waiting", 50, ["true"]))
        report = {"requesters": [{"holder": 950}], "warnings": []}
        self.assertEqual(g.claim(report), 50, "the key wait that follows belongs to the announced request")
        self.assertIsNone(g.claim({"requesters": [{"holder": 950}, {"holder": 980}], "warnings": ["2 requests at once"]}))

    def test_refused_without_a_notifier(self):
        b = FakeBroadcaster(connected=False)
        self.assertEqual(self.guard(b).decide(self.request()), (False, d.NO_NOTIFIER))
        self.assertEqual(b.published, [])

    def test_refused_when_not_shown(self):
        b = FakeBroadcaster(shows=False)
        g = self.guard(b)
        self.assertEqual(g.decide(self.request()), (False, d.NOT_SHOWN))
        self.assertEqual([e["event"] for e in b.published], ["waiting", "done"])
        self.assertEqual(g.active, {})

    def test_console_needs_no_notifier(self):
        allow, message = self.guard(FakeBroadcaster(connected=False)).decide(self.request(tty="/dev/tty3"))
        self.assertTrue(allow)
        self.assertTrue(message.startswith("touch-guard: sudo (runs as root)\n  true"), message)

    def test_gone_process(self):
        self.assertEqual(self.guard(FakeBroadcaster()).decide(self.request(pid=4242))[0], False)

    def test_sweep_ends_events_of_exited_programs(self):
        g = self.guard(FakeBroadcaster())
        g.decide(self.request())
        self.assertEqual(g.sweep(), [])
        with open(os.path.join(self.p.root, "950", "stat"), "w") as f:
            f.write("950 (sudo) S 901 " + " ".join(["0"] * 17) + " 999 0\n")
        self.assertEqual(g.sweep(), [50], "a reused pid is another process")

    def test_request_validation(self):
        self.assertIsNone(d.pam_request({"pid": "950"}))
        self.assertIsNone(d.pam_request({"pid": 1}))
        self.assertIsNone(d.pam_request([]))
        self.assertEqual(d.pam_request({"pid": 5, "tty": 7})["tty"], "")


class Store:
    """Fake NixOS systems in a fake store, with the store prefix pointed at it for the test."""

    def __init__(self, test, root):
        self.root = os.path.join(root, "nix", "store") + "/"
        os.makedirs(self.root)
        saved = d.STORE
        d.STORE = self.root
        test.addCleanup(setattr, d, "STORE", saved)
        self.count = 0
        self.kernel = self.file("linux-7.2", "kernel")

    def path(self, name):
        self.count += 1
        return f"{self.root}{self.count:032d}-{name}"

    def file(self, name, text):
        path = self.path(name)
        with open(path, "w") as f:
            f.write(text)
        return path

    def system(self, version="26.11.1", users=(), groups=(("wheel", ["dx"]),), pam="auth sufficient pam_u2f.so",
               nix="substituters = https://cache.nixos.org/", params="quiet", units=(), wrappers=("sudo",)):
        root = self.path("nixos-system-Quanta-" + version)
        etc = self.path("etc")
        os.makedirs(f"{etc}/etc/pam.d")
        os.makedirs(f"{etc}/etc/nix")
        os.makedirs(f"{etc}/etc/systemd/system")
        os.symlink(self.file("sudo-pam", pam), f"{etc}/etc/pam.d/sudo")
        with open(f"{etc}/etc/nix/nix.conf", "w") as f:
            f.write(nix + "\n")
        script = self.file("wrappers-start", "\n".join(
            f'cp /nix/store/{"9" * 32}-security-wrapper-{w} "$wrapperDir/{w}"\nchmod "u+s,g-s,u+rx,g+x" "$wrapperDir/{w}"'
            for w in wrappers))
        with open(f"{etc}/etc/systemd/system/suid-sgid-wrappers.service", "w") as f:
            f.write(f"[Service]\nExecStart={script} \n")
        for unit in units:
            with open(f"{etc}/etc/systemd/system/{unit}", "w") as f:
                f.write(f"[Service]\nExecStart=/nix/store/{'1' * 32}-{unit}\n")
        accounts = self.file("users-groups.json", json.dumps({
            "users": [{"name": "dx", "uid": None, "shell": "fish"}] + [{"name": u, "uid": uid} for u, uid in users],
            "groups": [{"name": g, "members": m} for g, m in groups]}))
        os.makedirs(f"{root}/bin")
        open(f"{root}/bin/switch-to-configuration", "w").close()
        os.symlink(f"{etc}/etc", f"{root}/etc")
        for name, text in (("nixos-version", version), ("kernel-params", params), ("activate", f"update {accounts}\n")):
            with open(f"{root}/{name}", "w") as f:
                f.write(text)
        os.symlink(self.kernel, f"{root}/kernel")
        return root


class SystemChanges(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = tmp.name
        self.s = Store(self, tmp.name)

    def changes(self, old, new, closures=None):
        return d.system_changes(new, old, lambda system: (closures or {}).get(system, []))

    def test_same_system(self):
        old = self.s.system()
        self.assertEqual(self.changes(old, old), (["this is the system that already runs"], []))

    def test_unchanged_config(self):
        self.assertEqual(self.changes(self.s.system(), self.s.system()), (["nothing that runs as root changes"], []))

    def test_root_access_changes_are_warnings(self):
        old = self.s.system()
        new = self.s.system(users=(("toor", 0),), groups=(("wheel", ["dx", "eve"]),), pam="auth sufficient pam_permit.so",
                            nix="substituters = https://cache.nixos.org/ https://evil.example",
                            params="quiet init=/bin/sh", wrappers=("sudo", "backdoor"))
        _, warnings = self.changes(old, new)
        self.assertEqual(warnings, ["changes root access config: pam.d/sudo",
                                    "changes what Nix trusts: substituters +https://evil.example",
                                    "changes setuid wrappers: +backdoor",
                                    "changes accounts: new user toor, wheel +eve",
                                    "changes kernel parameters: +init=/bin/sh"])

    def test_units_and_packages(self):
        old, new = self.s.system(), self.s.system(units=("evil.service",))
        sudo = lambda h: f"{self.s.root}{h * 32}-sudo-1.9.17"
        closures = {old: [sudo("a"), old], new: [sudo("b"), f"{self.s.root}{'c' * 32}-evil-1.0", new]}
        lines, warnings = self.changes(old, new, closures)
        self.assertEqual(warnings, [])
        self.assertEqual(lines, ["system units: +evil.service", "rebuilt at the same version: sudo-1.9.17",
                                 "packages added: evil-1.0"])

    def test_nixpkgs_update_skips_package_comparison(self):
        lines, _ = self.changes(self.s.system(version="26.11.1"), self.s.system(version="26.11.2"))
        self.assertEqual(lines, ["nixpkgs 26.11.1 → 26.11.2, its updates can hide other package changes"])

    def test_links_never_leave_the_store(self):
        outside = os.path.join(self.tmp, "outside")
        with open(outside, "w") as f:
            f.write("secret")
        link = self.s.path("link")
        os.symlink(outside, link)
        self.assertIsNone(d.store_resolve(link))
        self.assertIsNone(d.read_store(link))
        relative = self.s.path("relative")
        os.symlink("../../outside", relative)
        self.assertIsNone(d.store_resolve(relative), "a relative link can climb out of the store too")
        self.assertIsNone(d.store_resolve(outside))
        inside = self.s.file("inside", "x")
        chained = self.s.path("chained")
        os.symlink(os.path.basename(inside), chained)
        self.assertEqual(d.store_resolve(chained), inside)

    def test_not_a_system(self):
        old = self.s.system()
        lines, warnings = self.changes(old, self.s.file("hello-1.0", "x"))
        self.assertEqual(lines, [])
        self.assertTrue(warnings[0].startswith("the rebuild names something that is not a NixOS system"), warnings)


class PamHelper(unittest.TestCase):
    def setUp(self):
        self.path = os.path.join(tempfile.mkdtemp(), "pam.sock")
        self.requests = []

    def serve(self, answer):
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.path)
        server.listen(1)
        self.addCleanup(server.close)

        def run():
            conn, _ = server.accept()
            with conn, conn.makefile("rwb") as stream:
                self.requests.append(json.loads(stream.readline()))
                stream.write((json.dumps(answer) + "\n").encode())
                stream.flush()

        threading.Thread(target=run, daemon=True).start()

    def run_helper(self, *args, tty="/dev/pts/1"):
        env = {"PAM_SERVICE": "polkit-1", "PAM_USER": "dx", "PAM_TTY": tty}
        out = io.StringIO()
        with mock.patch.dict(os.environ, env), mock.patch.object(p, "CONNECT_WAIT", 0.2), contextlib.redirect_stdout(out):
            code = p.main(["--socket", self.path, *args])
        return code, out.getvalue().strip()

    def test_dialog_gets_the_description_and_the_cue_last(self):
        self.serve({"allow": True, "message": "touch-guard: run0 (runs as root)"})
        self.assertEqual(self.run_helper("--describe", "--key-cue"),
                         (0, "touch-guard: run0 (runs as root)\n" + p.KEY_CUE))
        self.assertEqual((self.requests[0]["service"], self.requests[0]["pid"]), ("polkit-1", os.getppid()))

    def test_terminals_stay_quiet_when_allowed(self):
        self.serve({"allow": True, "message": "touch-guard: sudo (runs as root)"})
        self.assertEqual(self.run_helper(), (0, ""))

    def test_refusal_is_explained(self):
        self.serve({"allow": False, "message": d.NO_NOTIFIER})
        self.assertEqual(self.run_helper("--describe"), (1, d.NO_NOTIFIER))

    def test_daemon_down(self):
        self.assertEqual(self.run_helper(), (1, p.DOWN))

    def test_console_passes_with_the_daemon_down(self):
        self.assertEqual(self.run_helper(tty="/dev/tty3"), (0, "touch-guard is not running"))


class Rendering(unittest.TestCase):
    def test_warnings_lead_and_markup_is_escaped(self):
        summary, body = n.render({"requesters": [{
            "title": "tool", "lines": ["/tmp/<b>x</b> --go"], "chain": "bash ← fish", "user": "dx",
            "pid": 5, "cwd": "/tmp", "warnings": ["not from your system: /tmp/x"]}], "warnings": []}, "dx")
        self.assertEqual(summary, "CHECK BEFORE TOUCHING")
        self.assertTrue(body.startswith("not from your system: /tmp/x\n<b>tool</b>"), body)
        self.assertIn("<b>tool</b>", body)
        self.assertIn("&lt;b&gt;x&lt;/b&gt;", body)

    def test_plain_request(self):
        summary, body = n.render({"requesters": [{
            "title": "sudo (runs as root)", "lines": ["true"], "chain": "fish ← konsole", "user": "dx",
            "pid": 9, "cwd": "", "warnings": []}], "warnings": []}, "dx")
        self.assertEqual(summary, "Touch for sudo (runs as root)")
        self.assertEqual(body, "true\nfrom fish ← konsole, pid 9")

    def test_other_users_are_named(self):
        _, body = n.render({"requesters": [{
            "title": "x", "lines": [], "chain": "", "user": "vm-win11", "pid": 3, "cwd": "", "warnings": []}],
            "warnings": []}, "dx")
        self.assertEqual(body, "from unknown, pid 3, user vm-win11")

    def test_fixed_bus_address(self):
        command = n.Notifications("/nix/store/x-systemd/bin/busctl").command
        self.assertEqual(command[:2], ["/nix/store/x-systemd/bin/busctl", f"--address=unix:path=/run/user/{os.getuid()}/bus"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

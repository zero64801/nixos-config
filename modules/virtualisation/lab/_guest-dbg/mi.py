"""gdb driven through its machine interface, by a program that decides at each stop what happens next."""
import os
import select
import subprocess
import time

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}


class Failed(Exception):
    """gdb refused a command, with its reason."""


def _string(text, at):
    out, at = bytearray(), at + 1
    while text[at] != '"':
        if text[at] == "\\":
            follow = text[at + 1]
            if follow in "01234567":
                out.append(int(text[at + 1:at + 4], 8))
                at += 4
                continue
            out += ESCAPES.get(follow, follow).encode()
            at += 2
            continue
        out += text[at].encode()
        at += 1
    return out.decode("utf-8", "replace"), at + 1


def _value(text, at):
    if text[at] == '"':
        return _string(text, at)
    if text[at] == "{":
        return _results(text, at + 1, "}")
    at += 1
    items = []
    if text[at] == "]":
        return items, at + 1
    while True:
        if text[at] in '"{[':
            item, at = _value(text, at)
        else:
            _, item, at = _result(text, at)
        items.append(item)
        if text[at] == ",":
            at += 1
            continue
        return items, at + 1


def _result(text, at):
    sign = text.index("=", at)
    value, end = _value(text, sign + 1)
    return text[at:sign], value, end


def _results(text, at, close):
    out = {}
    if close and text[at] == close:
        return out, at + 1
    while at < len(text):
        sign = text.index("=", at)
        name = text[at:sign]
        out[name], at = _value(text, sign + 1)
        if at < len(text) and text[at] == ",":
            at += 1
            continue
        break
    if close:
        return out, at + 1
    return out, at


def parse(text):
    """The results of one record, as dictionaries, lists and strings."""
    return _results(text, 0, None)[0] if text else {}


class Gdb:
    def __init__(self, program):
        self.process = subprocess.Popen([program, "--interpreter=mi3", "--nx", "--quiet"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL)
        self.out = self.process.stdout.fileno()
        self.held = b""
        self.token = 0
        self.stops = []

    def _line(self, until):
        while b"\n" not in self.held:
            left = until - time.monotonic()
            if left <= 0 or not select.select([self.out], [], [], left)[0]:
                return None
            more = os.read(self.out, 1 << 16)
            if not more:
                raise Failed("gdb ended")
            self.held += more
        line, self.held = self.held.split(b"\n", 1)
        return line.decode("utf-8", "replace").rstrip("\r")

    def _take(self, line):
        """Keeps what gdb said by itself, and gives back the console text of a line that is some."""
        if line.startswith("*stopped"):
            self.stops.append(parse(line[len("*stopped,"):]))
        elif line.startswith("~"):
            return _string(line, 1)[0]
        return None

    def run(self, command, wait=30):
        """Runs one command and gives back its results and what it printed."""
        self.token += 1
        mark = str(self.token)
        self.process.stdin.write(f"{mark}{command}\n".encode())
        self.process.stdin.flush()
        printed, until = [], time.monotonic() + wait
        while True:
            line = self._line(until)
            if line is None:
                raise Failed(f"gdb did not answer {command} within {wait} seconds")
            if line.startswith(mark + "^"):
                kind, _, rest = line[len(mark) + 1:].partition(",")
                values = parse(rest)
                if kind == "error":
                    raise Failed(values.get("msg", "an error"))
                return values, "".join(printed)
            text = self._take(line)
            if text is not None:
                printed.append(text)

    def console(self, command, wait=30):
        """What a command of gdb's own language prints."""
        return self.run("-interpreter-exec console " + '"' + command.replace("\\", "\\\\").replace('"', '\\"') + '"', wait)[1]

    def stopped(self, until):
        """The next stop, or None when there is none before the time."""
        while not self.stops:
            line = self._line(until)
            if line is None:
                return None
            self._take(line)
        return self.stops.pop(0)

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()

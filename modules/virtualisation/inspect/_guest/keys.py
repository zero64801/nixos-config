"""Keys and pointer events for the guest, which a session sends only when it was opened with --control."""
import sys
import time

from session import Refused, ask, control_socket, fail

# QEMU's range for an absolute axis, whatever the size of the guest's screen.
AXIS = 0x7fff

KEYS = {
    "enter": "ret", "return": "ret", "escape": "esc", "space": "spc", "del": "delete", "ins": "insert",
    "pageup": "pgup", "pagedown": "pgdn", "printscreen": "print", "win": "meta_l", "super": "meta_l", "meta": "meta_l",
    "control": "ctrl", "capslock": "caps_lock", "numlock": "num_lock",
}
PLAIN = {
    " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
    "\\": "backslash", ";": "semicolon", "'": "apostrophe", "`": "grave_accent", ",": "comma", ".": "dot", "/": "slash",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right", "|": "backslash", ":": "semicolon",
    '"': "apostrophe", "~": "grave_accent", "<": "comma", ">": "dot", "?": "slash",
}


def qcode(name):
    name = name.lower()
    return KEYS.get(name, name)


def key(name, down):
    return {"type": "key", "key": name, "down": down}


def button(name, down):
    return {"type": "btn", "button": name, "down": down}


def place(x, y, of):
    """Where on the guest's screen, from pixels of a picture of the given size or from fractions of the screen."""
    if of:
        try:
            width, height = (int(n) for n in of.lower().split("x"))
        except ValueError:
            fail("--of takes the size of a picture, as in 1920x1080")
        if width < 2 or height < 2:
            fail("--of takes the size of a picture, as in 1920x1080")
        x, y = x / (width - 1), y / (height - 1)
    if not (0 <= x <= 1 and 0 <= y <= 1):
        fail("a place is two fractions from 0 to 1, or pixels together with --of WIDTHxHEIGHT")
    return [{"type": "abs", "axis": "x", "value": round(x * AXIS)}, {"type": "abs", "axis": "y", "value": round(y * AXIS)}]


class Sender:
    def __init__(self, args):
        self.path = control_socket()
        self.hold = args.hold / 1000

    def send(self, *events):
        try:
            ask(self.path, {"do": "input", "events": list(events)})
        except Refused as e:
            fail(str(e))

    def press(self, names):
        """Keys go down in the order given and come up the other way round, as a hand does it."""
        self.send(*[key(n, True) for n in names])
        time.sleep(self.hold)
        self.send(*[key(n, False) for n in reversed(names)])
        time.sleep(self.hold)

    def click(self, name):
        self.send(button(name, True))
        time.sleep(self.hold)
        self.send(button(name, False))
        time.sleep(self.hold)


def keys_for(text):
    """The keys of a US keyboard that produce the text, which is what the guest has to be set to."""
    for letter in text:
        if letter in PLAIN:
            yield [PLAIN[letter]]
        elif letter in SHIFTED:
            yield ["shift", SHIFTED[letter]]
        elif letter.isascii() and letter.isalnum():
            yield ["shift", letter.lower()] if letter.isupper() else [letter]
        else:
            fail(f"{letter!r} is not on a US keyboard, so it cannot be typed")


def send_input(args):
    sender = Sender(args)
    if args.action == "key":
        for chord in args.keys:
            sender.press([qcode(name) for name in chord.split("+")])
    elif args.action == "type":
        text = sys.stdin.read() if args.text == "-" else args.text
        for names in list(keys_for(text)):
            sender.press(names)
    elif args.action == "move":
        sender.send(*place(args.x, args.y, args.of))
    elif args.action == "nudge":
        sender.send({"type": "rel", "axis": "x", "value": args.dx}, {"type": "rel", "axis": "y", "value": args.dy})
    elif args.action == "click":
        if args.at:
            sender.send(*place(args.at[0], args.at[1], args.of))
            time.sleep(sender.hold)
        for _ in range(2 if args.double else 1):
            sender.click(args.button)
    elif args.action == "scroll":
        for _ in range(abs(args.amount)):
            sender.click("wheel-up" if args.amount > 0 else "wheel-down")
    elif args.action == "drag":
        sender.send(*place(args.x, args.y, args.of))
        time.sleep(sender.hold)
        sender.send(button(args.button, True))
        time.sleep(sender.hold)
        # Halfway first, since a program that watches for a drag wants to see the pointer move while the button is down.
        sender.send(*place((args.x + args.to_x) / 2, (args.y + args.to_y) / 2, args.of))
        time.sleep(sender.hold)
        sender.send(*place(args.to_x, args.to_y, args.of))
        time.sleep(sender.hold)
        sender.send(button(args.button, False))

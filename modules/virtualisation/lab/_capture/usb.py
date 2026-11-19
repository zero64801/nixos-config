"""guest-usb: what passed between the guest and its USB devices, read from a session's capture.

usb.pcapng is written by the session in the format of Wireshark's USB captures on Linux: for each record the kernel's
header of 64 bytes and what it captured. A transfer is its submission and its completion, paired by the id they share.
Everything a device answers was made by the device, and everything the host sends by the guest's programs.
"""
import struct
from types import SimpleNamespace

from capture import common, fail, plain, timed

USB = "usb.pcapng"
KINDS = {0: "iso", 1: "int", 2: "ctrl", 3: "bulk"}
STANDARD = {0: "GET_STATUS", 1: "CLEAR_FEATURE", 3: "SET_FEATURE", 5: "SET_ADDRESS", 6: "GET_DESCRIPTOR", 7: "SET_DESCRIPTOR",
            8: "GET_CONFIGURATION", 9: "SET_CONFIGURATION", 10: "GET_INTERFACE", 11: "SET_INTERFACE", 12: "SYNCH_FRAME"}
HID = {1: "GET_REPORT", 2: "GET_IDLE", 3: "GET_PROTOCOL", 9: "SET_REPORT", 10: "SET_IDLE", 11: "SET_PROTOCOL"}
DESCRIPTORS = {1: "DEVICE", 2: "CONFIGURATION", 3: "STRING", 4: "INTERFACE", 5: "ENDPOINT", 6: "DEVICE_QUALIFIER", 15: "BOS",
               0x21: "HID", 0x22: "REPORT"}
REPORTS = {1: "input", 2: "output", 3: "feature"}
BLOCK_MAX = 64 * 1024 * 1024 + 4096


def records(path):
    """(seconds, record) for each packet of a pcapng file the session wrote."""
    resolution = 1e-6
    with open(path, "rb") as f:
        while True:
            head = f.read(8)
            if len(head) < 8:
                return
            kind, length = struct.unpack("<II", head)
            if length < 12 or length % 4 or length > BLOCK_MAX:
                fail(f"{path} is damaged")
            body = f.read(length - 8)
            if len(body) < length - 8:
                return
            if kind == 1:
                options = body[8:-4]
                at = 0
                while at + 4 <= len(options):
                    code, said = struct.unpack_from("<HH", options, at)
                    if code == 9 and said >= 1:
                        resolution = 10.0 ** -options[at + 4] if options[at + 4] < 128 else 2.0 ** -(options[at + 4] & 127)
                    if code == 0:
                        break
                    at += 4 + said + (-said % 4)
            elif kind == 6 and len(body) >= 24:
                _, high, low, captured, _ = struct.unpack_from("<IIIII", body)
                yield ((high << 32) | low) * resolution, body[20: 20 + captured]


class Transfer:
    def __init__(self, stamp, record):
        (self.id, kind, self.xfer, self.endpoint, self.device, self.bus, flag_setup, _, _, _, self.status, self.length, captured,
         self.setup, _, _, _, ndesc) = struct.unpack_from("<QBBBBHcc qiiII 8s iiII".replace(" ", ""), record)
        self.time, self.kind = stamp, chr(kind)
        self.has_setup = self.kind == "S" and self.xfer == 2 and flag_setup == b"\0"
        self.data = record[64 + ndesc * 16: 64 + captured] if captured > ndesc * 16 else b""
        self.answer = None

    @property
    def inward(self):
        """Whether data comes from the device, which for a control transfer its request says."""
        if self.has_setup:
            return bool(self.setup[0] & 0x80)
        return bool(self.endpoint & 0x80)

    def sent(self):
        """What the host sent: the data of an OUT transfer's submission."""
        return b"" if self.inward else self.data

    def got(self):
        """What the device answered: the data of an IN transfer's completion."""
        return self.answer.data if self.inward and self.answer else b""


def transfers(capture, args, path=None):
    """The transfers of the capture in the order they were submitted, each with its completion when there is one."""
    since = capture.moment(args.since) if getattr(args, "since", None) else None
    until = capture.moment(args.until) if getattr(args, "until", None) else None
    pending, done = {}, []
    for stamp, record in records(path or capture.file(USB)):
        if len(record) < 64:
            continue
        transfer = Transfer(stamp, record)
        if transfer.kind == "S":
            pending[transfer.id] = transfer
            done.append(transfer)
        elif transfer.id in pending:
            pending.pop(transfer.id).answer = transfer
    wanted = getattr(args, "device", None)
    return [t for t in done if (since is None or t.time >= since) and (until is None or t.time <= until)
            and (not wanted or f"{t.bus}.{t.device}" == wanted)]


def request(setup):
    """A control request in words."""
    kind, code = setup[0], setup[1]
    value, index, length = struct.unpack_from("<HHH", setup, 2)
    family = (kind >> 5) & 3
    if family == 0 and code == 6:
        name = f"GET_DESCRIPTOR {DESCRIPTORS.get(value >> 8, hex(value >> 8))} {value & 0xFF}"
    elif family == 0:
        name = f"{STANDARD.get(code, f'standard {code}')} value {value:#06x}"
    elif family == 1 and code in HID and code in (1, 9):
        name = f"{HID[code]} {REPORTS.get(value >> 8, hex(value >> 8))} report {value & 0xFF}"
    elif family == 1:
        name = f"class request {code:#04x}{' (' + HID[code] + ' for HID)' if code in HID else ''} value {value:#06x}"
    else:
        name = f"vendor request {code:#04x} value {value:#06x}"
    return f"{name} index {index} length {length}"


def hexed(data, limit):
    shown = data[:limit].hex(" ")
    return shown + (f" ... ({len(data)} bytes)" if len(data) > limit else "")


def urbs(capture, args):
    """Each transfer: when, which device and endpoint, what kind, and the data that went over it."""
    shown = 0
    for t in transfers(capture, args):
        if args.endpoint and f"{t.endpoint:#04x}" != args.endpoint.lower():
            continue
        if args.type and KINDS.get(t.xfer) != args.type:
            continue
        if shown >= args.max:
            print("... more, --max shows more")
            break
        shown += 1
        status = t.answer.status if t.answer else None
        ending = "no answer yet" if status is None else ("" if status == 0 else f"status {status}")
        what = request(t.setup) if t.has_setup else f"ep {t.endpoint:#04x} {KINDS.get(t.xfer, '?')} {'IN' if t.inward else 'OUT'}"
        data = t.got() if t.inward else t.sent()
        print(f"{capture.relative(t.time):>10} {t.bus}.{t.device:<3} {what}  {ending}  "
              f"{(str(len(data)) + ' B: ' + hexed(data, args.bytes)) if data else ''}".rstrip())


def control(capture, args):
    """The control requests, each kind once with how often it was made and what came back, in the order they first came."""
    seen = {}
    for t in transfers(capture, args):
        if not t.has_setup or (args.vendor and (t.setup[0] >> 5) & 3 == 0):
            continue
        key = (t.bus, t.device, t.setup, t.sent())
        entry = seen.setdefault(key, {"first": t.time, "count": 0, "answers": []})
        entry["count"] += 1
        if t.got() and t.got() not in entry["answers"]:
            entry["answers"].append(t.got())
    for (bus, device, setup, sent), entry in seen.items():
        print(f"{capture.relative(entry['first']):>10} {bus}.{device:<3} {request(setup)}  x{entry['count']}"
              + (f"  sends {hexed(sent, args.bytes)}" if sent else ""))
        for answer in entry["answers"][: args.answers]:
            print(f"{'':>15} gets {len(answer)} B: {hexed(answer, args.bytes)}")
        if len(entry["answers"]) > args.answers:
            print(f"{'':>15} ... {len(entry['answers']) - args.answers} more different answers")


def reports(capture, args):
    """Interrupt data, grouped by device, endpoint and first byte, with the bytes that changed and how far."""
    groups = {}
    for t in transfers(capture, args):
        if t.xfer != 1:
            continue
        data = t.got() if t.inward else t.sent()
        if not data:
            continue
        key = (t.bus, t.device, t.endpoint, data[0] if args.by_first else None)
        groups.setdefault(key, []).append(data)
    for (bus, device, endpoint, lead), rows in groups.items():
        width = max(len(r) for r in rows)
        moving = []
        for at in range(width):
            values = [r[at] for r in rows if len(r) > at]
            if len(set(values)) > 1:
                moving.append(f"{at}: {min(values)}..{max(values)} ({len(set(values))} values)")
        print(f"{bus}.{device} ep {endpoint:#04x} {'IN' if endpoint & 0x80 else 'OUT'}"
              + (f" first byte {lead:#04x}" if lead is not None else "") + f": {len(rows)} reports of {width} bytes")
        print("  changing bytes  " + ("; ".join(moving) if moving else "none"))
        distinct = list(dict.fromkeys(rows))
        for row in distinct[: args.rows]:
            print("  " + hexed(row, args.bytes))
        if len(distinct) > args.rows:
            print(f"  ... {len(distinct) - args.rows} more different reports")


def changes(capture, args):
    """What the host sent between two marks that it had not sent before the first, and the report bytes that moved only then."""
    capture.moment(args.start)
    before = SimpleNamespace(since=None, until=args.start, device=args.device)
    within = SimpleNamespace(since=args.start, until=args.end, device=args.device)
    old = transfers(capture, before)
    known = {(t.bus, t.device, t.endpoint, t.setup if t.has_setup else b"", t.sent()) for t in old}
    fresh = [t for t in transfers(capture, within) if (t.has_setup or not t.inward)
             and (t.bus, t.device, t.endpoint, t.setup if t.has_setup else b"", t.sent()) not in known]
    print(f"sent between {args.start} and {args.end} and never before:")
    for t in fresh[: args.max]:
        what = request(t.setup) if t.has_setup else f"ep {t.endpoint:#04x} {KINDS.get(t.xfer, '?')} OUT"
        print(f"  {capture.relative(t.time):>10} {t.bus}.{t.device:<3} {what}" + (f"  sends {hexed(t.sent(), args.bytes)}" if t.sent() else "")
              + (f"  gets {hexed(t.got(), args.bytes)}" if t.got() else ""))
    if not fresh:
        print("  nothing")
    steady = {}
    for t in old:
        if t.xfer == 1 and t.got():
            for at, value in enumerate(t.got()):
                steady.setdefault((t.bus, t.device, t.endpoint, at), set()).add(value)
    moved = {}
    for t in transfers(capture, within):
        if t.xfer == 1 and t.got():
            for at, value in enumerate(t.got()):
                key = (t.bus, t.device, t.endpoint, at)
                if key in steady and value not in steady[key]:
                    moved.setdefault(key, set()).add(value)
    print("report bytes with values they had not had before:")
    for (bus, device, endpoint, at), values in sorted(moved.items()):
        print(f"  {bus}.{device} ep {endpoint:#04x} byte {at}: {', '.join(f'{v:#04x}' for v in sorted(values)[:16])}")
    if not moved:
        print("  none")


def descriptor_answers(capture, args, kind):
    """The answers to GET_DESCRIPTOR of one type, with the device, index and interface they were for."""
    for t in transfers(capture, args):
        if t.has_setup and t.setup[0] & 0x80 and t.setup[1] == 6 and t.setup[3] == kind and t.got():
            yield t, t.setup[2], struct.unpack_from("<H", t.setup, 4)[0]


def devices(capture, args):
    """The devices the guest had, as this system's kernel named them, and what they told the guest of themselves."""
    said = capture.said
    for device in (said.get("usb") or []) + [d for d in said.get("plugged") or [] if d not in (said.get("usb") or [])]:
        plugged = device in (said.get("plugged") or [])
        print(f"{device.get('bus')}.{device.get('dev'):<3} {plain(device.get('id'), 20)}  {plain(device.get('manufacturer'), 60)} "
              f"{plain(device.get('product'), 80)}  serial {plain(device.get('serial') or '-', 60)}  {plain(device.get('speed'), 10)} Mb/s  "
              f"at {plain(device.get('place'), 20)}{'  plugged for the session' if plugged else ''}")
    found = {}
    for t, _, _ in descriptor_answers(capture, args, 1):
        data = t.got()
        if len(data) >= 18:
            version, klass = struct.unpack_from("<HB", data, 2)
            vendor, product, release = struct.unpack_from("<HHH", data, 8)
            found[(t.bus, t.device)] = (f"USB {version >> 8}.{(version >> 4) & 0xF} class {klass:#04x} id {vendor:04x}:{product:04x} "
                                        f"release {release >> 8}.{release & 0xFF:02x}")
    strings = {}
    for t, index, _ in descriptor_answers(capture, args, 3):
        if index and len(t.got()) >= 2:
            strings.setdefault((t.bus, t.device), {})[index] = t.got()[2: t.got()[0]].decode("utf-16-le", "replace")
    for key in sorted(set(found) | set(strings)):
        print(f"{key[0]}.{key[1]:<3} told the guest: {found.get(key, 'no device descriptor in the capture')}")
        for index, text in sorted(strings.get(key, {}).items()):
            print(f"      string {index}: {plain(text, 200)}")
    counts = {}
    for t in transfers(capture, args):
        counts[(t.bus, t.device)] = counts.get((t.bus, t.device), 0) + 1
    for (bus, device), count in sorted(counts.items()):
        print(f"{bus}.{device:<3} {count} transfers")


def hid(capture, args):
    """The HID report descriptors the guest read, as their items, with the size of each report they define."""
    shown = False
    for t, _, interface in descriptor_answers(capture, args, 0x22):
        shown = True
        print(f"{t.bus}.{t.device} interface {interface}, {len(t.got())} bytes")
        for line in items(t.got()):
            print("  " + line)
    if not shown:
        print("the capture holds no report descriptor, which the guest reads when the device is plugged in, so record from before that, as --plug does")


MAIN = {8: "Input", 9: "Output", 11: "Feature", 10: "Collection", 12: "End Collection"}
GLOBAL = {0: "Usage Page", 1: "Logical Minimum", 2: "Logical Maximum", 3: "Physical Minimum", 4: "Physical Maximum", 5: "Unit Exponent",
          6: "Unit", 7: "Report Size", 8: "Report ID", 9: "Report Count", 10: "Push", 11: "Pop"}
LOCAL = {0: "Usage", 1: "Usage Minimum", 2: "Usage Maximum", 3: "Designator Index", 7: "String Index", 10: "Delimiter"}
COLLECTIONS = {0: "Physical", 1: "Application", 2: "Logical", 3: "Report", 4: "Named Array", 5: "Usage Switch", 6: "Usage Modifier"}


def items(data):
    """The short items of a report descriptor, after the HID specification, 6.2.2, and the bits of each report."""
    lines, depth, at, state, sizes = [], 0, 0, {"size": 0, "count": 0, "id": 0}, {}
    while at < len(data):
        prefix = data[at]
        if prefix == 0xFE:
            length = data[at + 1] if at + 1 < len(data) else 0
            lines.append(f"{'  ' * depth}long item of {length} bytes")
            at += 3 + length
            continue
        width = (0, 1, 2, 4)[prefix & 3]
        kind, tag = (prefix >> 2) & 3, prefix >> 4
        raw = data[at + 1: at + 1 + width]
        value = int.from_bytes(raw, "little") if raw else 0
        signed = int.from_bytes(raw, "little", signed=True) if raw else 0
        at += 1 + width
        if kind == 0:
            name = MAIN.get(tag, f"main {tag}")
            if tag == 12:
                depth = max(depth - 1, 0)
            said = COLLECTIONS.get(value, hex(value)) if tag == 10 else (", ".join(
                ["constant" if value & 1 else "data", "variable" if value & 2 else "array", "relative" if value & 4 else "absolute"]) if tag in (8, 9, 11) else "")
            lines.append(f"{'  ' * depth}{name} {said}".rstrip())
            if tag == 10:
                depth += 1
            if tag in (8, 9, 11):
                key = (state["id"], MAIN[tag].lower())
                sizes[key] = sizes.get(key, 0) + state["size"] * state["count"]
        elif kind == 1:
            name = GLOBAL.get(tag, f"global {tag}")
            if tag == 7:
                state["size"] = value
            elif tag == 9:
                state["count"] = value
            elif tag == 8:
                state["id"] = value
            shown = f"{value:#06x}" if tag == 0 else (str(signed) if tag in (1, 2, 3, 4) else str(value))
            lines.append(f"{'  ' * depth}{name} {shown}")
        elif kind == 2:
            lines.append(f"{'  ' * depth}{LOCAL.get(tag, f'local {tag}')} {value:#06x}")
        else:
            lines.append(f"{'  ' * depth}reserved item {prefix:#04x}")
    for (report, kind), bits in sorted(sizes.items()):
        lines.append(f"{kind} report {report}: {bits} bits, {(bits + 7) // 8} bytes" + (" after its id byte" if report else ""))
    return lines


def passthrough(capture, args):
    import net
    net.passthrough(capture, args, USB)


def build(parser):
    actions = parser.add_subparsers(dest="action", required=True)

    def reader(name, function, about, timed_too=True):
        sub = actions.add_parser(name, help=about, description=about)
        common(sub)
        sub.add_argument("--device", metavar="BUS.DEV", help="only this device, as devices names it")
        if timed_too:
            timed(sub)
        sub.add_argument("--bytes", type=int, default=64, help="bytes of data to show of each, 64 by default")
        sub.set_defaults(run=function)
        return sub

    reader("devices", devices, "the devices the guest had, what this system's kernel and the devices themselves say they are, and how much went over each")
    sub = reader("urbs", urbs, "each transfer, with its data")
    sub.add_argument("--endpoint", help="only this endpoint, as 0x81")
    sub.add_argument("--type", choices=sorted(KINDS.values()))
    sub.add_argument("--max", type=int, default=300)
    sub = reader("control", control, "each kind of control request once, how often it was made and what came back")
    sub.add_argument("--vendor", action="store_true", help="only class and vendor requests, not the standard ones")
    sub.add_argument("--answers", type=int, default=3, help="different answers to show of each, 3 by default")
    sub = reader("reports", reports, "interrupt data grouped by endpoint, with the bytes that change and how far")
    sub.add_argument("--by-first", action="store_true", help="group by the first byte too, which is the report id of devices that use them")
    sub.add_argument("--rows", type=int, default=8, help="different reports to show of each group, 8 by default")
    sub = reader("changes", changes, "what the host sent between two marks that it had not sent before the first, and the report bytes that moved",
                 timed_too=False)
    sub.add_argument("start", metavar="MARK")
    sub.add_argument("end", metavar="MARK")
    sub.add_argument("--max", type=int, default=200)
    reader("hid", hid, "the HID report descriptors the guest read, item by item, with the size of each report", timed_too=False)
    sub = actions.add_parser("tshark", help="run tshark with these options on the capture, in the box", prefix_chars="\0")
    sub.add_argument("arguments", nargs="*")
    sub.set_defaults(run=passthrough, capture=None, keys=None)

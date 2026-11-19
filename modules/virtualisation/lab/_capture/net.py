"""guest-net: what the guest sent and got over its network, read from a session's capture.

A flow is named t then tshark's number for a TCP stream, or u for UDP. A request of HTTP is named h then the number of
the packet it began in. Everything shown was sent or received by the guest.
"""
import json
import os
import subprocess
import sys
import threading
import time

import bodies
import capture as shared
import owners
import scan
import schannel
from capture import KEYLOG, common, fail, finished, first, plain, size, tell, timed

NET = "net.pcapng"
SENT = "0x00000002"
FLOW_FIELDS = ["frame.time_epoch", "frame.len", "frame.packet_flags_direction", "ip.src", "ip.dst", "ipv6.src", "ipv6.dst",
               "tcp.stream", "udp.stream", "tcp.srcport", "tcp.dstport", "udp.srcport", "udp.dstport",
               "tls.handshake.extensions_server_name", "http.host", "dns.flags.response", "dns.qry.name", "dns.a", "dns.aaaa", "dns.cname"]


def joined(args, *parts):
    return " && ".join(f"({part})" for part in parts if part)


def endpoint(address, port):
    return f"[{address}]:{port}" if ":" in address else f"{address}:{port}"


def flows(capture, args, keys=None):
    """Every TCP and UDP flow, in the order they began, with what each side sent and the names it went by."""
    found, names = {}, {}
    for packet in capture.ek(NET, FLOW_FIELDS, joined(args, capture.window(args), "tcp || udp"), keys):
        tcp = first(packet, "tcp.stream")
        key = f"t{tcp}" if tcp else f"u{first(packet, 'udp.stream')}"
        proto = "tcp" if tcp else "udp"
        source = first(packet, "ip.src") or first(packet, "ipv6.src")
        target = first(packet, "ip.dst") or first(packet, "ipv6.dst")
        ports = (first(packet, f"{proto}.srcport"), first(packet, f"{proto}.dstport"))
        sent = first(packet, "frame.packet_flags_direction") == SENT
        stamp, length = float(first(packet, "frame.time_epoch", "0")), int(first(packet, "frame.len", "0"))
        flow = found.get(key)
        if flow is None:
            guest, other = ((source, ports[0]), (target, ports[1])) if sent else ((target, ports[1]), (source, ports[0]))
            flow = found[key] = {"id": key, "proto": proto, "guest": endpoint(*guest), "remote": endpoint(*other), "address": other[0],
                                 "began": stamp, "ended": stamp, "sent": 0, "got": 0, "packets": 0, "names": []}
        flow["ended"] = stamp
        flow["sent" if sent else "got"] += length
        flow["packets"] += 1
        for name in packet["tls.handshake.extensions_server_name"] + [host.rsplit(":", 1)[0] if host.count(":") == 1 else host for host in packet["http.host"]]:
            if name not in flow["names"]:
                flow["names"].append(name)
        if first(packet, "dns.flags.response") in ("1", "True", "true"):
            for address in packet["dns.a"] + packet["dns.aaaa"]:
                names.setdefault(address, first(packet, "dns.qry.name"))
    known = owners.known(capture)
    for flow in found.values():
        if not flow["names"] and flow["address"] in names:
            flow["names"].append(names[flow["address"]])
        flow["owner"] = owners.owner_of(known, flow)
    return sorted(found.values(), key=lambda flow: flow["began"])


def show_flows(capture, args):
    shown = [f for f in flows(capture, args, args.keys) if not args.name or any(args.name in n for n in f["names"])]
    if args.json:
        print(json.dumps(shown, indent=1))
        return
    for flow in shown[: args.max]:
        print(f"{flow['id']:<6} {capture.relative(flow['began']):>9} {flow['ended'] - flow['began']:7.2f}s {flow['proto']}  "
              f"{flow['guest']} -> {flow['remote']}  {plain(','.join(flow['names']) or '-', 80)}  "
              f"sent {size(flow['sent'])}, got {size(flow['got'])}, {flow['packets']} packets  {plain(flow['owner'] or '', 80)}")
    if len(shown) > args.max:
        print(f"... {len(shown) - args.max} more, --max shows more")


def dns(capture, args):
    """Every name the guest asked for, with what came back."""
    fields = ["frame.time_epoch", "dns.id", "dns.flags.response", "dns.qry.name", "dns.qry.type", "dns.flags.rcode", "dns.a", "dns.aaaa", "dns.cname"]
    asked, seen = {}, []
    for packet in capture.ek(NET, fields, joined(args, capture.window(args), "dns")):
        key = (first(packet, "dns.id"), first(packet, "dns.qry.name"), first(packet, "dns.qry.type"))
        if first(packet, "dns.flags.response") in ("1", "True", "true"):
            answers = packet["dns.a"] + packet["dns.aaaa"] + [f"alias {c}" for c in packet["dns.cname"]]
            code = first(packet, "dns.flags.rcode", "0")
            line = asked.pop(key, None) or {"time": first(packet, "frame.time_epoch"), "name": key[1], "type": key[2]}
            line["answer"] = ", ".join(answers) if answers else ("no such name" if code == "3" else f"no answer (code {code})")
            seen.append(line)
        else:
            asked[key] = {"time": first(packet, "frame.time_epoch"), "name": key[1], "type": key[2], "answer": "unanswered"}
    lines = sorted(seen + list(asked.values()), key=lambda line: float(line["time"] or 0))
    if not args.all:
        unique = {}
        for line in lines:
            unique.setdefault((line["name"], line["type"], line["answer"]), line)
        lines = list(unique.values())
    types = {"1": "A", "28": "AAAA", "5": "CNAME", "65": "HTTPS", "33": "SRV", "16": "TXT", "12": "PTR"}
    for line in lines[: args.max]:
        print(f"{capture.relative(line['time'] or capture.started):>9} {types.get(line['type'], line['type']):<5} "
              f"{plain(line['name'], 120)} -> {plain(line['answer'], 200)}")


HTTP_FIELDS = ["frame.number", "frame.time_epoch", "tcp.stream", "frame.packet_flags_direction", "http.request.method", "http.request.full_uri",
               "http.request.uri", "http.host", "http.response.code", "http.response.phrase", "http.content_type", "http.request_in",
               "http.content_length", "http.time"]
# Each HTTP/2 frame of a packet has a type and a stream, each HEADERS frame says how many headers it carries, and each DATA frame
# with a payload carries one piece of data, so the lists tshark gives are lined up frame by frame.
FRAME_FIELDS = ["http2.type", "http2.streamid", "http2.length", "http2.header.count", "http2.header.name", "http2.header.value", "http2.data.data"]


def frames(packet):
    """(type, stream, headers, data) of each HTTP/2 frame of a packet."""
    counts, pieces = iter(packet["http2.header.count"]), iter(packet["http2.data.data"])
    names, values = packet["http2.header.name"], packet["http2.header.value"]
    at = 0
    for kind, stream, length in zip(packet["http2.type"], packet["http2.streamid"], packet["http2.length"]):
        kind, headers, data = int(kind, 0), [], b""
        if kind == 1:
            count = int(next(counts, "0"), 0)
            headers = list(zip(names[at: at + count], values[at: at + count]))
            at += count
        elif kind == 0 and int(length, 0):
            data = bytes.fromhex(next(pieces, "").replace(":", ""))
        yield kind, stream, headers, data


def exchanges(capture, args, keys=None):
    """Each request of HTTP/1 and HTTP/2 with its answer, decrypted where the capture has the keys."""
    requests, streams = {}, {}
    for packet in capture.ek(NET, HTTP_FIELDS + FRAME_FIELDS, joined(args, capture.window(args), "http || http2.type == 1"), keys):
        number, stamp, tcp = first(packet, "frame.number"), first(packet, "frame.time_epoch"), first(packet, "tcp.stream")
        if packet["http.request.method"]:
            uri = first(packet, "http.request.full_uri") or f"http://{first(packet, 'http.host')}{first(packet, 'http.request.uri')}"
            requests[number] = {"id": f"h{number}", "time": stamp, "flow": f"t{tcp}", "method": first(packet, "http.request.method"),
                                "url": uri, "status": "", "type": "", "size": "", "answer": None, "version": "1", "took": None}
        elif packet["http.response.code"]:
            asked = requests.get(first(packet, "http.request_in"))
            if asked:
                asked.update(status=f"{first(packet, 'http.response.code')} {first(packet, 'http.response.phrase')}".strip(),
                             type=first(packet, "http.content_type"), size=first(packet, "http.content_length"), answer=number,
                             took=float(first(packet, "http.time", "0") or 0))
        for kind, stream, headers, _ in frames(packet):
            said = dict(headers)
            key = (tcp, stream)
            if kind == 1 and ":method" in said:
                url = f"{said.get(':scheme', 'https')}://{said.get(':authority', '?')}{said.get(':path', '')}"
                streams[key] = requests[f"{number}.{stream}"] = {"id": f"h{number}.{stream}", "time": stamp, "flow": f"t{tcp}", "method": said[":method"],
                                                                 "url": url, "status": "", "type": "", "size": "", "answer": None, "version": "2",
                                                                 "took": None}
            elif kind == 1 and ":status" in said and key in streams:
                streams[key].update(status=said[":status"], type=said.get("content-type", ""), size=said.get("content-length", ""),
                                    took=float(stamp) - float(streams[key]["time"]))
    return sorted(requests.values(), key=lambda r: float(r["time"]))


def http(capture, args):
    found = exchanges(capture, args, args.keys)
    known = owners.known(capture)
    flows_by_id = {f["id"]: f for f in flows(capture, args, args.keys)} if known else {}
    if args.id:
        detail(capture, args, [r for r in found if r["id"] == args.id])
        return
    for request in found[: args.max]:
        owner = owners.owner_of(known, flows_by_id[request["flow"]]) if request["flow"] in flows_by_id else ""
        took = f" in {request['took'] * 1000:.0f} ms" if request["took"] is not None else ""
        print(f"{request['id']:<10} {capture.relative(request['time']):>9} {request['flow']:<6} {request['method']} {plain(request['url'], 160)} -> "
              f"{plain(request['status'] or 'no answer', 40)}{took} {plain(request['type'], 60)} {request['size'] and size(int(request['size']))}  {plain(owner or '', 60)}")
    if not found:
        encrypted = sum(1 for f in flows(capture, args) if f["names"] and f["proto"] == "tcp")
        print("no HTTP in this capture" + (f", {encrypted} flows went to named hosts, see guest-net tls for those that are encrypted" if encrypted else ""))


def both_ways(capture, request, keys):
    """The headers and the body of an HTTP/2 request and of its answer, from the frames of its stream."""
    sent, got, asked, answer = [], [], b"", b""
    stream = request["id"].split(".")[1]
    for packet in capture.ek(NET, ["frame.packet_flags_direction"] + FRAME_FIELDS, f"tcp.stream == {request['flow'][1:]} && http2.streamid == {stream}", keys):
        from_guest = first(packet, "frame.packet_flags_direction") == SENT
        for _, number, headers, data in frames(packet):
            if number != stream:
                continue
            (sent if from_guest else got).extend(headers)
            if from_guest:
                asked += data
            else:
                answer += data
    return sent, got, asked, answer


def detail(capture, args, found):
    """A request with its headers and body, and its answer's, each body undone of its encoding and shown as text when it
    is text."""
    if not found:
        fail(f"there is no request {args.id}, guest-net http lists them")
    request = found[0]
    if request["version"] == "2":
        sent, got, asked, answer = both_ways(capture, request, args.keys)
        print(f"{request['method']} {plain(request['url'], 400)}")
        for name, value in sent:
            print(f"  {plain(name, 100)}: {plain(value, 400)}")
        show_body(args, asked, dict(sent), request=True)
        print(f"-> {plain(request['status'] or 'no answer', 80)}")
        for name, value in got:
            print(f"  {plain(name, 100)}: {plain(value, 400)}")
        show_body(args, answer, dict(got))
        return
    number = request["id"][1:]
    fields = ["http.request.line", "http.response.line", "http.file_data", "http.content_type", "http.content_encoding", "frame.number"]
    for packet in capture.ek(NET, fields, f"frame.number == {number} || http.request_in == {number}", args.keys):
        data = bytes.fromhex("".join(packet["http.file_data"]).replace(":", "")) if packet["http.file_data"] else b""
        # tshark has undone HTTP/1's encodings already where it could, and a body it left as it came is undone here.
        headers = {"content-type": first(packet, "http.content_type"), "content-encoding": first(packet, "http.content_encoding")}
        if packet["http.request.line"]:
            print(f"{request['method']} {plain(request['url'], 400)}")
            for line in packet["http.request.line"]:
                print("  " + plain(line.rstrip(), 400))
            show_body(args, data, headers, request=True)
        if packet["http.response.line"]:
            print(f"-> {plain(request['status'], 80)}")
            for line in packet["http.response.line"]:
                print("  " + plain(line.rstrip(), 400))
            show_body(args, data, headers)


def show_body(args, data, headers, request=False):
    """A body: undone of its encoding, written to ./out when asked, shown when it is text, and its size otherwise."""
    if not data:
        return
    headers = {name.lower(): value for name, value in headers.items()}
    data, note = bodies.decoded(data, headers.get("content-encoding", ""))
    side = "request body" if request else "body"
    shown = bodies.text(data, headers.get("content-type", ""), args.body) if args.body else None
    # tshark undoes the encodings it knows by itself, so a body that does not undo is only worth a word when it does not read.
    if note and shown is None:
        print(f"  ({side} {note})")
    if args.save:
        saved(f"{args.save}.request" if request else args.save, data)
        return
    if shown is None:
        print(f"  ({side}: {size(len(data))} that are not text, --save NAME writes it to ./out)")
    else:
        print(f"  {side}:" if request else "")
        print(plain(shown, args.body + 100))


def saved(name, data):
    """Writes data to ./out under the name asked for, never one the guest gave."""
    folder = os.path.realpath("out")
    path = os.path.realpath(os.path.join(folder, os.path.basename(name)))
    if not os.path.isdir(folder) or os.path.dirname(path) != folder:
        fail("there is no ./out folder to write to")
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
        f.write(data)
    print(f"{size(len(data))} written to {path}")


def tls(capture, args):
    """Each TLS handshake: the name asked for, the protocols offered, what the server chose, and whether the keys open it."""
    fields = ["frame.time_epoch", "tcp.stream", "udp.stream", "tls.handshake.type", "tls.handshake.extensions_server_name",
              "tls.handshake.extensions_alpn_str", "tls.handshake.ja4", "tls.handshake.extensions.supported_version",
              "tls.handshake.ciphersuite", "tls.handshake.version", "x509ce.dNSName"]
    found = {}
    for packet in capture.ek(NET, fields, joined(args, capture.window(args), "tls.handshake.type == 1 || tls.handshake.type == 2 || tls.handshake.type == 11"), args.keys):
        tcp = first(packet, "tcp.stream")
        key = f"t{tcp}" if tcp else f"u{first(packet, 'udp.stream')}"
        line = found.setdefault(key, {"time": first(packet, "frame.time_epoch"), "name": "", "alpn": "", "ja4": "", "version": "", "cipher": "", "certificate": ""})
        kinds = packet["tls.handshake.type"]
        if "1" in kinds:
            line.update(name=first(packet, "tls.handshake.extensions_server_name"), alpn=",".join(packet["tls.handshake.extensions_alpn_str"]),
                        ja4=first(packet, "tls.handshake.ja4"))
        if "2" in kinds:
            chosen = first(packet, "tls.handshake.extensions.supported_version") or first(packet, "tls.handshake.version")
            cipher = first(packet, "tls.handshake.ciphersuite")
            line.update(version={"0x0304": "1.3", "0x0303": "1.2", "0x0302": "1.1", "0x0301": "1.0"}.get(chosen, chosen),
                        cipher=CIPHERS.get(cipher, cipher))
        if "11" in kinds and packet["x509ce.dNSName"]:
            line["certificate"] = ",".join(packet["x509ce.dNSName"][:4])
    opened = set()
    if capture.keylog(args.keys):
        for packet in capture.ek(NET, ["tcp.stream"], "http || http2", args.keys):
            opened.add(f"t{first(packet, 'tcp.stream')}")
    for key, line in sorted(found.items(), key=lambda item: float(item[1]["time"] or 0))[: args.max]:
        state = "decrypted" if key in opened else ("encrypted" if capture.keylog(args.keys) else "encrypted, the capture has no keys")
        print(f"{key:<6} {capture.relative(line['time']):>9} {plain(line['name'] or '-', 80)}  TLS {line['version'] or '?'} {line['cipher']} "
              f"{plain(line['alpn'], 40)}  ja4 {plain(line['ja4'], 60) or '-'}  {('cert ' + plain(line['certificate'], 120) + '  ') if line['certificate'] else ''}{state}")


# The cipher suites of TLS 1.3 and the common ones of 1.2, by the names of their RFCs.
CIPHERS = {"0x1301": "TLS_AES_128_GCM_SHA256", "0x1302": "TLS_AES_256_GCM_SHA384", "0x1303": "TLS_CHACHA20_POLY1305_SHA256",
           "0xc02b": "ECDHE_ECDSA_AES_128_GCM_SHA256", "0xc02c": "ECDHE_ECDSA_AES_256_GCM_SHA384", "0xc02f": "ECDHE_RSA_AES_128_GCM_SHA256",
           "0xc030": "ECDHE_RSA_AES_256_GCM_SHA384", "0xcca8": "ECDHE_RSA_CHACHA20_POLY1305", "0xcca9": "ECDHE_ECDSA_CHACHA20_POLY1305",
           "0x009c": "RSA_AES_128_GCM_SHA256", "0x009d": "RSA_AES_256_GCM_SHA384", "0x002f": "RSA_AES_128_CBC_SHA", "0x0035": "RSA_AES_256_CBC_SHA"}


def stream(capture, args):
    """What went each way in one flow, as text with what is not text escaped, or as hex."""
    kind = {"t": "tcp", "u": "udp"}.get(args.id[:1])
    if not kind or not args.id[1:].isdigit():
        fail("a flow is t or u and a number, as guest-net flows names them")
    follow = "tls" if args.decrypted else kind
    text = capture.output(NET, ["-q", "-z", f"follow,{follow},raw,{args.id[1:]}"], args.keys)
    lines = text.splitlines()
    nodes = [line.split(":", 1)[1].strip() for line in lines if line.startswith("Node ")]
    chunks, sent, got = [], b"", b""
    for line in lines:
        data = line.strip()
        if not data or line.startswith(("Node ", "=", "Follow:", "Filter:")) or any(c not in "0123456789abcdef" for c in data):
            continue
        raw = bytes.fromhex(data)
        # tshark indents what the second node sent, and the first node is the one that spoke first.
        chunks.append((line.startswith("\t"), raw))
    guest_first = flows_first_sender(capture, args)
    total = 0
    for second, raw in chunks:
        from_guest = second != guest_first
        if from_guest:
            sent += raw
        else:
            got += raw
        if total < args.max:
            shown = raw[: args.max - total]
            total += len(shown)
            print(f"{'-> the guest sent' if from_guest else '<- the guest got'} {len(raw)} bytes")
            print(hexdump(shown) if args.hex else escaped(shown))
    if args.save:
        saved(args.save + ".sent", sent)
        saved(args.save + ".got", got)
    if not chunks:
        print(f"nothing went over {args.id}" + (", or the keys do not open it" if args.decrypted else ""))
    elif nodes:
        print(f"(between {plain(nodes[0], 60)} and {plain(nodes[-1], 60)}, {size(len(sent))} sent and {size(len(got))} got)")


def flows_first_sender(capture, args):
    """Whether the guest spoke first in the flow, which is how the two sides tshark follows are told apart."""
    proto = "tcp" if args.id[0] == "t" else "udp"
    for packet in capture.ek(NET, ["frame.packet_flags_direction"], f"{proto}.stream == {args.id[1:]} && {proto}.len > 0" if proto == "tcp" else f"udp.stream == {args.id[1:]}"):
        return first(packet, "frame.packet_flags_direction") == SENT
    return True


def escaped(data):
    out = []
    for byte in data:
        if byte in (9, 10) or 32 <= byte < 127:
            out.append(chr(byte))
        elif byte == 13:
            continue
        else:
            out.append(f"\\x{byte:02x}")
    return "".join(out)


def hexdump(data):
    lines = []
    for at in range(0, len(data), 16):
        piece = data[at: at + 16]
        lines.append(f"{at:08x}  {piece.hex(' '):<47}  {''.join(chr(b) if 32 <= b < 127 else '.' for b in piece)}")
    return "\n".join(lines)


def body(capture, args):
    """The body of an answer, or with --request of the request, written to ./out undone of its encoding."""
    found = [r for r in exchanges(capture, args, args.keys) if r["id"] == args.id]
    if not found:
        fail(f"there is no request {args.id}, guest-net http lists them")
    name = args.save or f"body-{args.id}.bin"
    if found[0]["version"] == "2":
        sent, got, asked, answer = both_ways(capture, found[0], args.keys)
        data, headers = (asked, dict(sent)) if args.request else (answer, dict(got))
    else:
        display = f"frame.number == {args.id[1:]}" if args.request else f"http.request_in == {args.id[1:]}"
        packet = next(iter(capture.ek(NET, ["http.file_data", "http.content_encoding"], display, args.keys)), None)
        if packet is None:
            fail(f"{args.id} got no answer with a body")
        data = bytes.fromhex("".join(packet["http.file_data"]).replace(":", "")) if packet["http.file_data"] else b""
        headers = {"content-encoding": first(packet, "http.content_encoding")}
    data, note = bodies.decoded(data, {k.lower(): v for k, v in headers.items()}.get("content-encoding", ""))
    if note:
        print(f"the body is {note}")
    saved(name, data)


def packets(capture, args):
    """tshark's line for each packet, as in Wireshark's list, with a display filter."""
    fields = ["frame.number", "frame.time_relative", "frame.packet_flags_direction", "_ws.col.def_src", "_ws.col.def_dst", "_ws.col.protocol", "frame.len", "_ws.col.info"]
    for shown, packet in enumerate(capture.ek(NET, fields, joined(args, capture.window(args), args.filter or ""), args.keys)):
        if shown >= args.max:
            print("... more, --max shows more")
            break
        way = "->" if first(packet, "frame.packet_flags_direction") == SENT else "<-"
        print(f"{first(packet, 'frame.number'):>6} {float(first(packet, 'frame.time_relative', '0')):9.3f} {way} "
              f"{plain(first(packet, '_ws.col.def_src'), 40)} > {plain(first(packet, '_ws.col.def_dst'), 40)} {plain(first(packet, '_ws.col.protocol'), 12)} "
              f"{first(packet, 'frame.len')} {plain(first(packet, '_ws.col.info'), 200)}")


def passthrough(capture, args, file=NET):
    """Any tshark options on the capture, inside the box, with what it prints made safe."""
    process = capture.tshark(file, args.arguments, args.keys)
    for line in process.stdout:
        print(plain(line.decode("utf-8", "replace").rstrip("\n"), 4000))
    process.wait()
    if process.returncode:
        for line in process.stderr.read().decode("utf-8", "replace").splitlines()[-5:]:
            print(plain(line, 400), file=sys.stderr)
    sys.exit(process.returncode)


def watch(capture, args):
    """Names asked for, requests and TLS handshakes as they happen, until the session ends or the time is up."""
    path = capture.file(NET)
    fields = ["frame.time_epoch", "frame.packet_flags_direction", "dns.flags.response", "dns.qry.name", "dns.a", "http.request.method",
              "http.request.full_uri", "http.response.code", "tls.handshake.extensions_server_name", "tcp.stream", "udp.stream"]
    display = "(dns && dns.flags.response == 1) || http.request || http.response || tls.handshake.type == 1"
    arguments = ["-l", "-Y", display, "-T", "ek"] + [a for f in fields for a in ("-e", f)]
    process = capture.tshark(None, arguments, args.keys, stdin=subprocess.PIPE)
    until = time.monotonic() + args.seconds if args.seconds else None

    def feed():
        # tshark reads the file as it grows, from a pipe, as it would a live interface.
        with open(path, "rb") as f:
            try:
                while until is None or time.monotonic() < until:
                    piece = f.read(1 << 20)
                    if piece:
                        process.stdin.write(piece)
                        process.stdin.flush()
                    elif capture.ended():
                        break
                    else:
                        time.sleep(0.2)
            except (BrokenPipeError, OSError):
                pass
        try:
            process.stdin.close()
        except OSError:
            pass

    threading.Thread(target=feed, daemon=True).start()
    try:
        for line in process.stdout:
            if not line.startswith(b'{"timestamp"'):
                continue
            layers = json.loads(line).get("layers", {})
            packet = {field: layers.get(field.replace(".", "_"), []) for field in fields}
            flow = f"t{first(packet, 'tcp.stream')}" if first(packet, "tcp.stream") else f"u{first(packet, 'udp.stream')}"
            when = capture.relative(first(packet, "frame.time_epoch", str(capture.started)))
            if first(packet, "dns.qry.name"):
                print(f"{when:>9} {flow:<6} name {plain(first(packet, 'dns.qry.name'), 120)} -> {plain(', '.join(packet['dns.a']) or '?', 120)}")
            elif first(packet, "http.request.method"):
                print(f"{when:>9} {flow:<6} {first(packet, 'http.request.method')} {plain(first(packet, 'http.request.full_uri'), 200)}")
            elif first(packet, "http.response.code"):
                print(f"{when:>9} {flow:<6} answer {first(packet, 'http.response.code')}")
            elif first(packet, "tls.handshake.extensions_server_name"):
                print(f"{when:>9} {flow:<6} TLS to {plain(first(packet, 'tls.handshake.extensions_server_name'), 120)}")
            sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        process.kill()


def export(capture, args):
    """A copy of the capture, or of a part of it, into ./out, with the TLS secrets in it when asked for."""
    folder = os.path.realpath("out")
    if not os.path.isdir(folder):
        fail("there is no ./out folder to write to")
    name = os.path.basename(args.file or f"net-{os.path.basename(capture.folder)}.pcapng")
    target = os.path.join(folder, name)
    if os.path.exists(target):
        fail(f"{target} exists already")
    display = joined(args, capture.window(args), args.filter or "")
    out = ["--rw", folder]
    command = (["-Y", display] if display else []) + ["-w", target]
    process = capture.tshark(NET, command, args.keys, binds=[out])
    process.stdout.read()
    finished(process)
    keylog = capture.keylog(args.keys)
    if args.decrypted:
        if not keylog:
            fail("the capture has no keys to put in")
        with_keys = target + ".keys"
        box = [shared.SETTINGS.box, "--ro", keylog, "--rw", folder, "--", shared.SETTINGS.editcap, "--inject-secrets", f"tls,{keylog}", target, with_keys]
        done = subprocess.run(box, capture_output=True, check=False)
        if done.returncode != 0:
            fail(f"editcap could not put the keys in: {plain(done.stderr.decode('utf-8', 'replace'), 200)}")
        os.replace(with_keys, target)
    print(f"{size(os.path.getsize(target))} written to {target}" + (", with the TLS secrets in it" if args.decrypted else ""))


def summary(capture, args):
    said = capture.said
    took = (time.mktime(time.strptime(said["ended"], "%Y-%m-%d %H:%M:%S")) - capture.started) if said.get("ended") else None
    print(f"capture  {capture.folder}")
    print(f"recorded {said['started']} " + (f"for {took:.0f} s" if took is not None else "and still recording")
          + f", {said.get('frames', 0)} frames, {size(said.get('bytes', 0))}, {said.get('frames_dropped', 0)} dropped by the kernel")
    if said.get("stopped"):
        print(f"stopped  {plain(said['stopped'])}")
    for device in said.get("net") or []:
        print(f"device   {plain(device['name'], 40)} ({plain(device['mac'], 40)})")
    for left in said.get("left") or []:
        print(f"left out {plain(left)}")
    print("marks    " + (", ".join(f"{plain(label, 60)} {capture.relative(stamp)}" for label, stamp in capture.marks) or "none"))
    keys = capture.keylog(None)
    if keys:
        with open(keys) as f:
            print(f"keys     {sum(1 for _ in f)}")
    else:
        print("keys     none, so TLS stays encrypted")
    seen = list(capture.lines("owners.jsonl"))
    print(f"owners   {len(seen)} sightings" if seen else "owners   none, guest-net owners --follow finds the program of each connection")
    if said.get("net"):
        found = flows(capture, args)
        names = sorted({name for flow in found for name in flow["names"]})
        print(f"flows    {sum(f['proto'] == 'tcp' for f in found)} tcp, {sum(f['proto'] == 'udp' for f in found)} udp")
        print(f"names    {plain(', '.join(names), 2000) or 'none'}")


def keys(capture, args):
    """TLS secrets for the capture: added from a key log of this side, pulled from the guest, read from lsass, or listed."""
    if args.action == "schannel":
        schannel.run(capture, args)
        return
    if args.action == "scan":
        scan.run(capture, args, flows(capture, args))
        return
    if args.action == "list":
        found = capture.keylog(None)
        if not found:
            print("the capture has no keys")
            return
        counts = {}
        with open(found) as f:
            for line in f:
                counts[line.split(" ", 1)[0]] = counts.get(line.split(" ", 1)[0], 0) + 1
        for label, count in sorted(counts.items()):
            print(f"{label} {count}")
        return
    if args.action == "pull":
        if not args.path:
            fail("pull takes the key log's path in the guest")
        local = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"guest-keys-{os.getpid()}.log")
        done = subprocess.run(["guest-pull", "--max", "64M", args.path, local], capture_output=True, text=True, check=False)
        if done.returncode != 0:
            fail(f"the key log could not be pulled: {plain(done.stderr.strip(), 300)}")
        path = local
    else:
        if not args.path:
            fail("add takes a key log of this side")
        path = args.path
    with open(path, errors="replace") as f:
        lines = [line.strip() for line in f if line.strip()]
    good = [line for line in lines if KEYLOG.fullmatch(line)]
    for at in range(0, len(good), 4096):
        tell({"do": "note", "kind": "keys", "lines": good[at: at + 4096]})
    print(f"{len(good)} lines added to the capture's keys" + (f", {len(lines) - len(good)} that are no key log lines left out" if len(lines) > len(good) else ""))



def build(parser):
    actions = parser.add_subparsers(dest="action", required=True)

    def reader(name, function, about, *, timed_too=True):
        sub = actions.add_parser(name, help=about, description=about)
        common(sub)
        sub.add_argument("--keys", metavar="FILE", help="a TLS key log of this side, used with the capture's own keys")
        if timed_too:
            timed(sub)
        sub.set_defaults(run=function)
        return sub

    sub = actions.add_parser("captures", help="list the captures of this guest, or of the guest named")
    sub.add_argument("domain", nargs="?", default=os.environ.get("VM_INSPECT_DOMAIN"))
    sub.set_defaults(run=None)
    reader("summary", summary, "what the capture holds, its marks, keys and the names the guest reached")
    sub = reader("flows", show_flows, "every TCP and UDP flow: the two ends, the names they go by, what went each way and whose program it was")
    sub.add_argument("--name", help="only flows to a name with this in it")
    sub.add_argument("--max", type=int, default=200)
    sub.add_argument("--json", action="store_true")
    sub = reader("dns", dns, "the names the guest looked up and the answers it got")
    sub.add_argument("--all", action="store_true", help="every lookup, not only the first of each answer")
    sub.add_argument("--max", type=int, default=500)
    sub = reader("http", http, "the requests of HTTP/1 and HTTP/2 and their answers, or one of them in full")
    sub.add_argument("id", nargs="?", help="a request as the list names it, to show its headers and the answer's body")
    sub.add_argument("--save", metavar="NAME", help="write the answer's body to ./out under this name, and the request's as NAME.request")
    sub.add_argument("--body", type=int, default=4000, help="characters of a text body to show, 4000 by default")
    sub.add_argument("--max", type=int, default=300)
    sub = reader("tls", tls, "each TLS handshake: the name asked for, the version and cipher chosen, the client's JA4, whether the keys open it")
    sub.add_argument("--max", type=int, default=300)
    sub = reader("stream", stream, "what went each way in one flow", timed_too=False)
    sub.add_argument("id", help="the flow, as t12 or u3")
    sub.add_argument("--decrypted", action="store_true", help="what went inside TLS, which takes the keys")
    sub.add_argument("--hex", action="store_true")
    sub.add_argument("--max", type=int, default=65536, help="bytes to show, 64 KiB by default")
    sub.add_argument("--save", metavar="NAME", help="write both ways to ./out as NAME.sent and NAME.got")
    sub = reader("body", body, "write the body of an answer, or of the request, to ./out", timed_too=False)
    sub.add_argument("id", help="the request, as h41")
    sub.add_argument("--save", metavar="NAME")
    sub.add_argument("--request", action="store_true", help="the request's body instead of the answer's")
    sub = reader("packets", packets, "Wireshark's line for each packet, with a display filter")
    sub.add_argument("filter", nargs="?", help="a display filter of Wireshark, such as 'tcp.port == 443'")
    sub.add_argument("--max", type=int, default=200)
    sub = reader("watch", watch, "show names, requests and TLS handshakes as the guest makes them", timed_too=False)
    sub.add_argument("--seconds", type=float, help="stop after this long, otherwise when the session ends or on Ctrl-C")
    sub = actions.add_parser("owners", help="find which program of the guest each connection belongs to, and keep it in the capture",
                             description="Find which program of the guest each connection belongs to, and keep it in the capture for flows and http. "
                                         "In a Windows guest it is read from the guest's memory, which the guest does not see. Elsewhere it is asked "
                                         "of the guest through the agent, which needs a session opened with --control.")
    common(sub)
    sub.add_argument("--follow", action="store_true", help="keep looking until stopped, as connections come and go")
    sub.add_argument("--every", type=float, default=1.0, help="seconds between looks, 1 by default")
    sub.add_argument("--from", dest="source", choices=["memory", "agent"], help="memory for a Windows guest, agent elsewhere, found out otherwise")
    sub.set_defaults(run=owners.run)
    sub = actions.add_parser("keys", help="TLS secrets for the capture: add a key log, pull one from the guest, read Windows' own from lsass, "
                                          "find any program's in its memory, or list them",
                             description="TLS secrets for the capture, which every reader decrypts with. add takes a key log of this side, pull "
                                         "one a program in the guest wrote, as one with SSLKEYLOGFILE does. schannel follows lsass of a Windows "
                                         "guest from outside, with the CPU's debug registers, and adds the secrets of every handshake of "
                                         "Windows' own TLS as it happens: start it before the connections. lsass stops for a moment at each. "
                                         "scan finds the secrets of the capture's TLS flows in the memory of the programs that made them, "
                                         "while they run, and adds only those that open the flow's own records.")
    common(sub)
    timed(sub)
    sub.add_argument("action", choices=["add", "pull", "schannel", "scan", "list"])
    sub.add_argument("path", nargs="?", help="the key log, of this side for add and of the guest for pull")
    sub.add_argument("--seconds", type=float, help="for schannel: stop after this long, otherwise on Ctrl-C")
    sub.add_argument("--flow", action="append", metavar="ID", help="for scan: only this flow, as t12, more than once for several")
    sub.add_argument("--process", action="append", metavar="NAME", help="for scan: search this process, by name or number, for every flow")
    sub.add_argument("--physical", action="store_true", help="for scan: search the guest's whole RAM around the client randoms, for any guest")
    sub.add_argument("--deep", action="store_true", help="for scan with --physical: then all of the RAM, which takes long")
    sub.add_argument("--step", type=int, help="for scan: try windows that start at multiples of this, by default every one in up to "
                                                     "32 MiB and every eighth beyond")
    sub.add_argument("--around", type=int, default=65536, help="for scan: bytes searched each side of a client random, 64 KiB by default")
    sub.add_argument("--max-memory", type=int, default=4096, metavar="MIB", help="for scan: memory read of a process at most, 4096 MiB by default")
    sub.add_argument("--again", action="store_true", help="for scan: also flows the capture has keys for")
    sub.add_argument("--follow", action="store_true", help="for scan: copy the memory of each new TLS flow's program as it begins, "
                                                            "which catches programs that close their connections at once")
    sub.add_argument("--pause", action="store_true", help="for scan --follow: hold the whole guest still while copying, through the "
                                                           "debug stub, which keys schannel and guest-gdb then cannot use")
    sub.add_argument("--keep", type=int, default=64, metavar="MIB", help="for scan --follow: keep a program's whole memory when it "
                                                                           "is no larger than this, 64 MiB by default, otherwise only "
                                                                           "around the client random")
    sub.set_defaults(run=keys)
    sub = reader("export", export, "copy the capture, or a part of it, to ./out, with --decrypted with its TLS secrets in it")
    sub.add_argument("file", nargs="?", help="the name in ./out")
    sub.add_argument("--filter", help="only packets that match this display filter")
    sub.add_argument("--decrypted", action="store_true")
    sub = actions.add_parser("tshark", help="run tshark with these options on the capture, in the box", prefix_chars="\0")
    sub.add_argument("arguments", nargs="*")
    sub.set_defaults(run=passthrough, capture=None, keys=None)

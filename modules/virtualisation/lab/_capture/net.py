"""guest-net: what the guest sent and got over its network, read from a session's capture.

A flow is named t then tshark's number for a TCP stream, or u for UDP. A request of HTTP is named h then the number of
the packet it began in. Everything shown was sent or received by the guest. --process and --host keep the flows of some
programs or to some hosts, as scope.py chooses them.
"""
import argparse
import base64
import bisect
import calendar
import datetime
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.parse

import bodies
import capture as shared
import grpc
import owners
import scan
import schannel
import scope
import tlsrecords
import websocket
from capture import KEYLOG, common, fail, finished, first, plain, size, tell, timed
from scope import Scope

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
        best = owners.best(known, flow)
        flow["owner"] = f"{best.get('process')}[{best.get('pid')}]" if best else ""
        flow["pid"], flow["process"] = (best.get("pid"), best.get("process")) if best else (None, None)
    return sorted(found.values(), key=lambda flow: flow["began"])


def scoped(capture, args, found=None):
    """The flows --process and --host keep, of the whole capture so that a flow begun before --since counts, and the display
    filter for their packets, empty when neither was given."""
    chosen = Scope(capture, args)
    if not chosen:
        return found, ""
    kept = chosen.keep(found if found is not None else flows(capture, None, args.keys))
    return kept, chosen.display(kept)


def show_flows(capture, args):
    chosen = Scope(capture, args)
    shown = [f for f in flows(capture, args, args.keys) if not args.name or any(args.name in n for n in f["names"])]
    if chosen:
        shown = chosen.keep(shown)
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
    """Every name the guest asked for, with what came back. With --process the names its flows went to, which in Windows
    the DNS client service looks up for every program."""
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
    chosen = Scope(capture, args)
    if chosen:
        kept = chosen.keep(flows(capture, None)) if chosen.processes else None
        names = {name.lower() for flow in kept or [] for name in flow["names"]}
        addresses = {flow["address"] for flow in kept or []}

        def wanted(line):
            answers = line["answer"].split(", ")
            if kept is not None and line["name"].lower() not in names and not addresses & set(answers):
                return False
            return chosen.host([line["name"]], "") or any(chosen.host([], answer) for answer in answers)

        lines = [line for line in lines if wanted(line)]
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


def epoch(text):
    """frame.time_epoch, which tshark's JSON gives as a date in UTC and its ek as seconds."""
    try:
        return float(text)
    except ValueError:
        whole, _, fraction = str(text).rstrip("Z").partition(".")
        return calendar.timegm(time.strptime(whole, "%Y-%m-%dT%H:%M:%S")) + float("0." + (fraction if fraction.isdigit() else "0"))


def quic_streams(capture, keys, only):
    """The stream data of each QUIC connection the keys open, as h3.py takes it: by connection, in the order of the packets,
    each chunk with the side that sent it, 0 for the client. Only the side that opens a unidirectional stream sends on it,
    and the client opens those of even number, which tells the sides apart even when the client's first requests went as
    early data that the keys do not open."""
    if not capture.keylog(keys):
        return []
    text = capture.output(NET, ["-Y", joined(None, only, "quic.stream_data"), "-T", "json", "--no-duplicate-keys", "-J", "frame udp quic"], keys)
    try:
        packets = json.loads(text) if text.strip() else []
    except ValueError:
        fail("tshark's JSON of the QUIC streams does not read")
    connections = {}

    def listed(value):
        return value if isinstance(value, list) else [value] if isinstance(value, dict) else []

    for packet in packets:
        layers = packet.get("_source", {}).get("layers", {})
        frame, udp = layers.get("frame", {}), layers.get("udp", {})
        if not isinstance(frame, dict) or not isinstance(udp, dict):
            continue
        flow = f"u{udp.get('udp.stream', '?')}"
        try:
            sent = int(frame.get("frame.packet_flags", "0"), 16) & 3 == int(SENT, 16)
        except ValueError:
            sent = False
        connection = connections.setdefault(flow, {"flow": flow, "chunks": [], "guest_is_client": None, "guessed": None})
        for quic in listed(layers.get("quic")):
            for each in listed(quic.get("quic.frame")):
                data = each.get("quic.stream_data")
                if not isinstance(data, str):
                    continue
                try:
                    stream, offset = int(each.get("quic.stream.stream_id", "-1")), int(each.get("quic.stream.offset", "0"))
                    when, number = epoch(frame.get("frame.time_epoch", "0")), int(frame.get("frame.number", "0"))
                except ValueError:
                    continue
                if stream < 0:
                    continue
                if connection["guest_is_client"] is None and stream & 2:
                    connection["guest_is_client"] = sent == (stream & 1 == 0)
                if connection["guessed"] is None and not stream & 3:
                    connection["guessed"] = sent
                fin = str(each.get("quic.frame_type_tree", {}).get("quic.stream.fin", "0")) == "1"
                connection["chunks"].append((when, number, sent, stream, offset, bytes.fromhex(data.replace(":", "")), fin))
    out = []
    for connection in connections.values():
        known = connection["guest_is_client"] if connection["guest_is_client"] is not None else connection["guessed"]
        guest_is_client = known is not False
        events = [[when, number, 0 if sent == guest_is_client else 1, stream, offset, base64.b64encode(data).decode(), fin]
                  for when, number, sent, stream, offset, data, fin in connection["chunks"]]
        out.append({"flow": connection["flow"], "events": events})
    return out


def http3(capture, args, keys=None, only=""):
    """The requests of HTTP/3 with their answers, from QUIC's streams, taken apart by h3.py inside lab-box. tshark reads HTTP/3
    itself only with the secrets of the handshake, and this needs only those of the traffic."""
    connections = quic_streams(capture, keys, only)
    if not connections:
        return []
    command = [shared.SETTINGS.box, "--", sys.executable, "-I", "-B", os.path.join(os.path.dirname(os.path.abspath(__file__)), "h3.py")]
    done = subprocess.run(command, input=json.dumps({"connections": connections}).encode(), capture_output=True, check=False)
    if done.returncode != 0:
        fail(f"HTTP/3 could not be read: {plain(done.stderr.decode('utf-8', 'replace').strip().splitlines()[-1:] or 'no reason', 300)}")
    try:
        said = json.loads(done.stdout)
    except ValueError:
        fail("the reader of HTTP/3 gave no answer")
    since = capture.moment(args.since) if getattr(args, "since", None) else None
    until = capture.moment(args.until) if getattr(args, "until", None) else None
    found = []
    for request in said.get("requests", []):
        if (since and request["time"] < since) or (until and request["time"] > until):
            continue
        answer = dict(request["headers"])
        body = base64.b64decode(request["body"])
        found.append({"id": request["id"], "time": str(request["time"]), "flow": request["flow"], "method": request["method"], "url": request["url"],
                      "status": answer.get(":status", ""), "type": answer.get("content-type", ""),
                      "size": answer.get("content-length", "") or (str(len(body)) if body else ""), "answer": None, "version": "3",
                      "took": request["took"], "sent": request["request_headers"] + request.get("request_trailers", []),
                      "got": request["headers"] + request["trailers"],
                      "protocol": dict(request["request_headers"]).get(":protocol", ""),
                      "asked": base64.b64decode(request["request_body"]), "body": body})
    # Only what concerns the connections shown, and with one request asked for only its own.
    shown = {r["flow"] for r in found if not getattr(args, "id", None) or r["id"] == args.id}
    for note in [n for n in said.get("notes", []) if isinstance(n, str) and n.split(":")[0].split(" ")[0] in shown][:20]:
        print(f"guest-net: {plain(note, 300)}", file=sys.stderr)
    return found


def exchanges(capture, args, keys=None, only=""):
    """Each request of HTTP/1, HTTP/2 and HTTP/3 with its answer, decrypted where the capture has the keys, of the flows the
    display filter only keeps."""
    requests, streams = {}, {}
    for packet in capture.ek(NET, HTTP_FIELDS + FRAME_FIELDS, joined(args, capture.window(args), only, "http || http2.type == 1"), keys):
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
                                                                 "took": None, "protocol": said.get(":protocol", "")}
            elif kind == 1 and ":status" in said and key in streams:
                streams[key].update(status=said[":status"], type=said.get("content-type", ""), size=said.get("content-length", ""),
                                    took=float(stamp) - float(streams[key]["time"]))
    return sorted(list(requests.values()) + http3(capture, args, keys, only), key=lambda r: float(r["time"]))


def http(capture, args):
    known = owners.known(capture)
    every = flows(capture, None, args.keys) if known or Scope(capture, args) else []
    _, only = scoped(capture, args, every)
    found = exchanges(capture, args, args.keys, only)
    flows_by_id = {f["id"]: f for f in every}
    if args.id:
        detail(capture, args, [r for r in found if r["id"] == args.id])
        return
    for request in found[: args.max]:
        owner = owners.owner_of(known, flows_by_id[request["flow"]]) if request["flow"] in flows_by_id else ""
        took = f" in {request['took'] * 1000:.0f} ms" if request["took"] is not None else ""
        if request["status"].startswith("101") or request.get("protocol") == "websocket":
            took += f" websocket, guest-net ws {request['flow'] if request['version'] == '1' else request['id']}"
        print(f"{request['id']:<10} {capture.relative(request['time']):>9} {request['flow']:<6} {request['method']} {plain(request['url'], 160)} -> "
              f"{plain(request['status'] or 'no answer', 40)}{took} {plain(request['type'], 60)} {request['size'] and size(int(request['size']))}  {plain(owner or '', 60)}")
    if not found:
        encrypted = sum(1 for f in (scoped(capture, args, flows(capture, args))[0]) if f["names"] and f["proto"] == "tcp")
        print(f"no HTTP in {'the flows chosen' if only else 'this capture'}"
              + (f", {encrypted} flows went to named hosts, see guest-net tls for those that are encrypted" if encrypted else ""))


def h2_streams(capture, keys, display):
    """The headers and the data of each HTTP/2 stream the display filter keeps, both ways, as {(tcp stream, stream): [the
    headers the guest sent, those it got, what it sent, what it got]}, in one reading."""
    found = {}
    for packet in capture.ek(NET, ["frame.packet_flags_direction", "tcp.stream"] + FRAME_FIELDS, display, keys):
        from_guest = first(packet, "frame.packet_flags_direction") == SENT
        for _, number, headers, data in frames(packet):
            parts = found.setdefault((first(packet, "tcp.stream"), number), [[], [], bytearray(), bytearray()])
            parts[0 if from_guest else 1].extend(headers)
            if len(parts[2 if from_guest else 3]) + len(data) <= bodies.LIMIT:
                parts[2 if from_guest else 3] += data
    return found


def both_ways(capture, request, keys):
    """The headers and the body of an HTTP/2 request and of its answer, from the frames of its stream."""
    tcp, stream = request["flow"][1:], request["id"].split(".")[1]
    sent, got, asked, answer = h2_streams(capture, keys, f"tcp.stream == {tcp} && http2.streamid == {stream}").get((tcp, stream), [[], [], b"", b""])
    return sent, got, bytes(asked), bytes(answer)


def http_parts(capture, args, keys, only, found):
    """The headers and bodies of each request found and of its answer, as {id: (headers sent, body sent, headers got, body
    got)}, read once for HTTP/1 and once for HTTP/2, while HTTP/3's come with the request."""
    parts = {}
    numbers = {r["id"][1:] for r in found if r["version"] == "1"}
    if numbers:
        fields = ["frame.number", "http.request_in", "http.request.line", "http.response.line", "http.file_data"]
        for packet in capture.ek(NET, fields, joined(args, only, "http"), keys):
            number, asked_in = first(packet, "frame.number"), first(packet, "http.request_in")
            data = bytes.fromhex("".join(packet["http.file_data"]).replace(":", "")) if packet["http.file_data"] else b""
            if packet["http.request.line"] and number in numbers:
                parts.setdefault(f"h{number}", [[], b"", [], b""])[0:2] = [header_lines(packet["http.request.line"]), data]
            elif packet["http.response.line"] and asked_in in numbers:
                parts.setdefault(f"h{asked_in}", [[], b"", [], b""])[2:4] = [header_lines(packet["http.response.line"]), data]
    if any(r["version"] == "2" for r in found):
        streams = h2_streams(capture, keys, joined(args, only, "http2.type == 0 || http2.type == 1"))
        for r in found:
            if r["version"] == "2":
                sent, got, asked, answer = streams.get((r["flow"][1:], r["id"].split(".")[1]), [[], [], b"", b""])
                parts[r["id"]] = [sent, bytes(asked), got, bytes(answer)]
    for r in found:
        if r["version"] == "3":
            parts[r["id"]] = [r["sent"], r["asked"], r["got"], r["body"]]
    return parts


def header_lines(lines):
    """(name, value) of each header line of HTTP/1 as tshark gives them."""
    found = []
    for line in lines:
        name, colon, value = line.rstrip("\r\n").partition(":")
        if colon:
            found.append((name.strip(), value.strip()))
    return found


def har(capture, args):
    """The requests of the flows and time chosen with their answers as a HAR 1.2 file in ./out, for browser developer tools,
    Fiddler and other readers of HAR. Bodies are undone of their encoding, and those that are not text go as base64."""
    known = owners.known(capture)
    every = flows(capture, None, args.keys)
    _, only = scoped(capture, args, every)
    found = exchanges(capture, args, args.keys, only)
    parts = http_parts(capture, args, args.keys, only, found)
    by_id = {f["id"]: f for f in every}

    def content(data, headers, request):
        said = {name.lower(): value for name, value in headers}
        data, note = bodies.decoded(data, said.get("content-encoding", ""))
        kind = said.get("content-type", "")
        shown = {"mimeType": kind, "size": len(data)} if not request else {"mimeType": kind}
        try:
            shown["text"] = data.decode("utf-8")
        except UnicodeDecodeError:
            shown["text"], shown["encoding"] = base64.b64encode(data).decode(), "base64"
        if note:
            shown["comment"] = note
        return shown

    entries = []
    for request in found:
        sent, asked, got, answer = parts.get(request["id"], [[], b"", [], b""])
        flow = by_id.get(request["flow"])
        status, _, phrase = request["status"].partition(" ")
        version = {"1": "HTTP/1.1", "2": "h2", "3": "h3"}[request["version"]]
        query = urllib.parse.parse_qsl(urllib.parse.urlsplit(request["url"]).query, keep_blank_values=True)
        took = round(request["took"] * 1000, 3) if request["took"] is not None else 0
        entry = {"startedDateTime": datetime.datetime.fromtimestamp(float(request["time"]), datetime.UTC).isoformat().replace("+00:00", "Z"),
                 "time": took,
                 "request": {"method": request["method"], "url": request["url"], "httpVersion": version, "cookies": [],
                             "headers": [{"name": n, "value": v} for n, v in sent], "queryString": [{"name": n, "value": v} for n, v in query],
                             "headersSize": -1, "bodySize": len(asked)},
                 "response": {"status": int(status) if status.isdigit() else 0, "statusText": phrase, "httpVersion": version, "cookies": [],
                              "headers": [{"name": n, "value": v} for n, v in got], "content": content(answer, got, False), "redirectURL": "",
                              "headersSize": -1, "bodySize": len(answer)},
                 "cache": {}, "timings": {"blocked": -1, "dns": -1, "connect": -1, "ssl": -1, "send": 0, "wait": took, "receive": 0},
                 "connection": request["flow"], "_program": owners.owner_of(known, flow) if flow else ""}
        if asked:
            entry["request"]["postData"] = content(asked, sent, True)
        if flow:
            entry["serverIPAddress"] = flow["address"]
        entries.append(entry)
    log = {"log": {"version": "1.2", "creator": {"name": "guest-net", "version": "1"}, "pages": [], "entries": entries,
                   "comment": f"what the guest {capture.said.get('domain', '')} sent and got, from {capture.folder}"}}
    saved(os.path.basename(args.file or f"http-{os.path.basename(capture.folder)}.har"), json.dumps(log, indent=1).encode())
    print(f"{len(entries)} requests")


def detail(capture, args, found):
    """A request with its headers and body, and its answer's, each body undone of its encoding and shown as text when it
    is text."""
    if not found:
        fail(f"there is no request {args.id}, guest-net http lists them")
    request = found[0]
    if request["version"] in ("2", "3"):
        sent, got, asked, answer = (request["sent"], request["got"], request["asked"], request["body"]) if request["version"] == "3" else \
            both_ways(capture, request, args.keys)
        print(f"{request['method']} {plain(request['url'], 400)}")
        for name, value in sent:
            print(f"  {plain(name, 100)}: {plain(value, 400)}")
        path = request["url"].split("://", 1)[-1].partition("/")[2]
        show_body(args, asked, dict(sent), request=True, path="/" + path)
        print(f"-> {plain(request['status'] or 'no answer', 80)}")
        for name, value in got:
            print(f"  {plain(name, 100)}: {plain(value, 400)}")
        show_body(args, answer, dict(got), path="/" + path, asked=dict(sent))
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


def sockets(capture, args, keys, only):
    """The WebSockets of the flows kept, each as its opening and its messages in order: HTTP/1's from tshark, which unmasks
    their frames, and those that a CONNECT of HTTP/2 or HTTP/3 opened from the bytes of its stream, which carry no times of
    their own."""
    found = {}
    fields = ["tcp.stream", "frame.time_epoch", "http.request.full_uri", "http.upgrade", "http.response.code", "http.sec_websocket_extensions"]
    for packet in capture.ek(NET, fields, joined(None, only, "http.upgrade || http.response.code == 101"), keys):
        socket = found.setdefault(f"t{first(packet, 'tcp.stream')}", {"time": float(first(packet, "frame.time_epoch", "0")), "url": "", "agreed": "", "messages": []})
        uri = first(packet, "http.request.full_uri")
        if uri.startswith("http") and "websocket" in ",".join(packet["http.upgrade"]).lower():
            socket["url"] = "ws" + uri[4:]
        if first(packet, "http.response.code") == "101":
            socket["agreed"] = ", ".join(packet["http.sec_websocket_extensions"])
    text = capture.output(NET, ["-Y", joined(None, only, "websocket"), "-T", "json", "--no-duplicate-keys", "-J", "frame tcp websocket"], keys)
    try:
        packets = json.loads(text) if text.strip() else []
    except ValueError:
        fail("tshark's JSON of the WebSockets does not read")
    sides = {}
    for packet in packets:
        layers = packet.get("_source", {}).get("layers", {})
        frame, tcp = layers.get("frame", {}), layers.get("tcp", {})
        if not isinstance(frame, dict) or not isinstance(tcp, dict):
            continue
        flow = f"t{tcp.get('tcp.stream', '?')}"
        try:
            sent, when = int(frame.get("frame.packet_flags", "0"), 16) & 3 == int(SENT, 16), epoch(frame.get("frame.time_epoch", "0"))
        except ValueError:
            continue
        socket = found.setdefault(flow, {"time": when, "url": "", "agreed": "", "messages": []})
        frames_ = layers.get("websocket")
        for each in frames_ if isinstance(frames_, list) else [frames_]:
            if not isinstance(each, dict):
                continue
            try:
                opcode = int(each.get("websocket.opcode", "-1"))
                payload = bytes.fromhex(str(each.get("websocket.payload", "")).replace(":", ""))
            except ValueError:
                continue
            said = sides.setdefault((flow, sent), websocket.Messages()).add(each.get("websocket.fin") == "1", each.get("websocket.pmc") == "1", opcode, payload)
            if said:
                socket["messages"].append((when, sent, *said))
    for request in exchanges(capture, None, keys, only):
        if request.get("protocol") != "websocket":
            continue
        if request["version"] == "3":
            asked, answer = request["asked"], request["body"]
        else:
            _, _, asked, answer = both_ways(capture, request, keys)
        socket = found[request["id"]] = {"time": float(request["time"]), "url": request["url"].replace("https://", "wss://", 1), "agreed": "", "messages": []}
        for sent, data in ((True, asked), (False, answer)):
            messages = websocket.Messages()
            for each in websocket.frames(data):
                said = messages.add(*each)
                if said:
                    socket["messages"].append((float(request["time"]), sent, *said))
    return found


def ws(capture, args):
    """The messages of each WebSocket, or of one in full, both ways."""
    known = owners.known(capture)
    every = flows(capture, None, args.keys) if known or Scope(capture, args) else []
    _, only = scoped(capture, args, every)
    by_id = {f["id"]: f for f in every}
    since = capture.moment(args.since) if getattr(args, "since", None) else None
    until = capture.moment(args.until) if getattr(args, "until", None) else None
    found = sockets(capture, args, args.keys, only)
    if args.id and args.id not in found:
        fail(f"there is no WebSocket {args.id}, guest-net ws lists them")
    saved_lines = []
    for name, socket in sorted(found.items(), key=lambda item: item[1]["time"]):
        if args.id and name != args.id:
            continue
        flow = by_id.get(name) or by_id.get(name.split(".")[0])
        owner = owners.owner_of(known, flow) if flow else ""
        print(f"{name:<10} {capture.relative(socket['time']):>9} {plain(socket['url'] or '?', 200)}  {plain(socket['agreed'], 120)}  "
              f"{len(socket['messages'])} messages  {plain(owner, 60)}")
        shown = [m for m in socket["messages"] if (since is None or m[0] >= since) and (until is None or m[0] <= until)]
        for when, sent, kind, data, deflated, note in shown[: args.max]:
            if kind == "close":
                said = websocket.closed(data)
            elif kind in ("text", "ping", "pong"):
                said = (bodies.text(data, "", args.body) if args.id else None) or data.decode("utf-8", "replace")
            else:
                said = data[:48].hex(" ") + (" ..." if len(data) > 48 else "")
            print(f"  {capture.relative(when):>9} {'->' if sent else '<-'} {kind} {size(len(data))}{' deflated' if deflated else ''}"
                  f"{'  (' + note + ')' if note else ''}  {plain(said, args.body)}")
            saved_lines.append({"socket": name, "time": when, "sent": sent, "kind": kind, "deflated": deflated,
                                **({"text": data.decode("utf-8", "replace")} if kind == "text" else {"base64": base64.b64encode(data).decode()})})
        if len(shown) > args.max:
            print(f"  ... {len(shown) - args.max} more, --max shows more")
    if not found:
        print("no WebSocket in " + ("the flows chosen" if only else "this capture"))
    if args.save:
        saved(args.save, "".join(json.dumps(line) + "\n" for line in saved_lines).encode())


def show_body(args, data, headers, request=False, path="", asked=None):
    """A body: undone of its encoding, written to ./out when asked, shown when it is text, and its size otherwise. One of
    gRPC shows as its messages, which take the request's content type when the answer names its own only in trailers."""
    if not data:
        return
    headers = {name.lower(): value for name, value in headers.items()}
    kind = headers.get("content-type") or {name.lower(): value for name, value in (asked or {}).items()}.get("content-type", "")
    if kind.startswith("application/grpc") and not args.save:
        print(f"  {'request body' if request else 'body'}, gRPC:")
        for line in grpc.shown(data, {**headers, "content-type": kind}, path, request, getattr(args, "proto", None), getattr(args, "type", None),
                               shared.SETTINGS.box, shared.SETTINGS.protoc, args.body):
            print(plain(line, args.body + 100))
        return
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
    _, only = scoped(capture, args)
    for packet in capture.ek(NET, fields, joined(args, capture.window(args), only, "tls.handshake.type == 1 || tls.handshake.type == 2 || tls.handshake.type == 11"), args.keys):
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
        for packet in capture.ek(NET, ["tcp.stream", "udp.stream"], joined(args, only, "http || http2 || quic.stream_data"), args.keys):
            opened.add(f"t{first(packet, 'tcp.stream')}" if first(packet, "tcp.stream") else f"u{first(packet, 'udp.stream')}")
    for key, line in sorted(found.items(), key=lambda item: float(item[1]["time"] or 0))[: args.max]:
        state = "decrypted" if key in opened else ("encrypted" if capture.keylog(args.keys) else "encrypted, the capture has no keys")
        print(f"{key:<6} {capture.relative(line['time']):>9} {plain(line['name'] or '-', 80)}  TLS {line['version'] or '?'} {line['cipher']} "
              f"{plain(line['alpn'], 40)}  ja4 {plain(line['ja4'], 60) or '-'}  {('cert ' + plain(line['certificate'], 120) + '  ') if line['certificate'] else ''}{state}")


# The cipher suites of TLS 1.3 and the common ones of 1.2, by the names of their RFCs.
CIPHERS = {"0x1301": "TLS_AES_128_GCM_SHA256", "0x1302": "TLS_AES_256_GCM_SHA384", "0x1303": "TLS_CHACHA20_POLY1305_SHA256",
           "0xc02b": "ECDHE_ECDSA_AES_128_GCM_SHA256", "0xc02c": "ECDHE_ECDSA_AES_256_GCM_SHA384", "0xc02f": "ECDHE_RSA_AES_128_GCM_SHA256",
           "0xc030": "ECDHE_RSA_AES_256_GCM_SHA384", "0xcca8": "ECDHE_RSA_CHACHA20_POLY1305", "0xcca9": "ECDHE_ECDSA_CHACHA20_POLY1305",
           "0x009c": "RSA_AES_128_GCM_SHA256", "0x009d": "RSA_AES_256_GCM_SHA384", "0x002f": "RSA_AES_128_CBC_SHA", "0x0035": "RSA_AES_256_CBC_SHA",
           "0x1304": "TLS_AES_128_CCM_SHA256", "0x1305": "TLS_AES_128_CCM_8_SHA256", "0xc0ac": "ECDHE_ECDSA_AES_128_CCM",
           "0xc0ae": "ECDHE_ECDSA_AES_128_CCM_8", "0xc09c": "RSA_AES_128_CCM", "0x000a": "RSA_3DES_EDE_CBC_SHA", "0xc012": "ECDHE_RSA_3DES_EDE_CBC_SHA",
           "0x0005": "RSA_RC4_128_SHA", "0x0004": "RSA_RC4_128_MD5", "0xc011": "ECDHE_RSA_RC4_128_SHA"}


def stream(capture, args):
    """What went each way in one flow, as text with what is not text escaped, or as hex."""
    if args.id[:1] not in ("t", "u") or not args.id[1:].isdigit():
        fail("a flow is t or u and a number, as guest-net flows names them")
    flow = next((f for f in flows(capture, None, args.keys) if f["id"] == args.id), None)
    if flow is None:
        fail(f"there is no flow {args.id}, guest-net flows lists them")
    taken = chunks(capture, flow, args.decrypted, args.keys)
    sent, got, total = b"", b"", 0
    for _, from_guest, raw in taken:
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
    if not taken:
        print(f"nothing went over {args.id}" + (", or the keys do not open it" if args.decrypted else ""))
    else:
        print(f"(between {plain(flow['guest'], 60)} and {plain(flow['remote'], 60)}, {size(len(sent))} sent and {size(len(got))} got)")


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
    if found[0]["version"] == "3":
        data, headers = (found[0]["asked"], dict(found[0]["sent"])) if args.request else (found[0]["body"], dict(found[0]["got"]))
    elif found[0]["version"] == "2":
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
    _, only = scoped(capture, args)
    for shown, packet in enumerate(capture.ek(NET, fields, joined(args, capture.window(args), only, args.filter or ""), args.keys)):
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
    """A copy of the capture, or of a part of it, into ./out, with the TLS secrets in it when asked for, or its requests as HAR."""
    if args.har:
        har(capture, args)
        return
    folder = os.path.realpath("out")
    if not os.path.isdir(folder):
        fail("there is no ./out folder to write to")
    name = os.path.basename(args.file or f"net-{os.path.basename(capture.folder)}.pcapng")
    target = os.path.join(folder, name)
    if os.path.exists(target):
        fail(f"{target} exists already")
    _, only = scoped(capture, args)
    display = joined(args, capture.window(args), only, args.filter or "")
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
        chosen = Scope(capture, args)
        if chosen:
            found = chosen.keep(found)
            print(f"chosen   {', '.join(sorted(chosen.names | {str(n) for n in chosen.numbers}) + chosen.domains + [str(n) for n in chosen.networks])}"
                  f"{' and the programs they started' if chosen.children else ''}")
        names = sorted({name for flow in found for name in flow["names"]})
        print(f"flows    {sum(f['proto'] == 'tcp' for f in found)} tcp, {sum(f['proto'] == 'udp' for f in found)} udp")
        print(f"names    {plain(', '.join(names), 2000) or 'none'}")


def chunks(capture, flow, decrypted, keys):
    """What went each way in one flow, in order, as tshark follows it: (time, whether the guest sent it, bytes), from inside
    TLS when decrypted. Which way each went comes from its frame, which the capture keeps, since in TLS 1.3 the server may
    speak first. tshark numbers the streams of TLS apart from those of TCP, so one is followed by its two ends."""
    kind = "tcp" if flow["proto"] == "tcp" else "udp"
    sent = {first(packet, "frame.number"): first(packet, "frame.packet_flags_direction") == SENT
            for packet in capture.ek(NET, ["frame.number", "frame.packet_flags_direction"], f"{kind}.stream == {flow['id'][1:]}", keys)}
    which = f"tls,yaml,{flow['guest']},{flow['remote']}" if decrypted and kind == "tcp" else f"{kind},yaml,{flow['id'][1:]}"
    text = capture.output(NET, ["-q", "-z", f"follow,{which}"], keys)
    found, current = [], None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("- packet:"):
            current = {"packet": stripped.split(":", 1)[1].strip(), "data": ""}
            found.append(current)
        elif current is not None and stripped.startswith("timestamp:"):
            current["timestamp"] = stripped.split(":", 1)[1].strip()
        elif current is not None and stripped and not stripped.startswith(("data:", "peer:", "index:")):
            current["data"] += stripped
    out = []
    for packet in found:
        try:
            out.append((float(packet.get("timestamp", "0")), sent.get(packet["packet"], False), base64.b64decode(packet["data"])))
        except ValueError:
            continue
    if decrypted and kind == "tcp":
        # A direction tshark opened nothing of may be one keys scan found the keys of only after their updates.
        sides = {from_guest for _, from_guest, _ in out}
        out = sorted(out + [c for c in after_updates(capture, flow) if c[1] not in sides], key=lambda c: c[0])
    return out


def after_updates(capture, flow):
    """What went each way in a TLS 1.3 flow from the newest key update keys scan found the secret of, opened here, since
    tshark opens a flow only from its first secrets, which a program no longer holds once it updated them. Each later
    update met on the way turns the secret into the next."""
    secrets = scan.updated(capture)
    stream = flow["id"][1:]
    data = scan.whole(capture, {stream}) if secrets else {}
    if stream not in data:
        return []
    (guest, guest_marks), (other, other_marks) = data[stream]
    found, guest_is_client = tlsrecords.session(guest, other), True
    if not found:
        found, guest_is_client = tlsrecords.session(other, guest), False
    known = secrets.get(found.client_random.hex()) if found and found.version == 0x0304 else None
    if not known:
        return []
    scanner, out = scan.Scanner(shared.SETTINGS.scan), []
    for side, marks, from_guest in ((guest, guest_marks, True), (other, other_marks, False)):
        role = "CLIENT" if from_guest == guest_is_client else "SERVER"
        epochs = sorted(int(label.rsplit("_", 1)[1]) for label in known if label.startswith(role + "_"))
        if not epochs:
            continue
        kept, _ = tlsrecords.updates(side, found.suite)
        secret, seq = known[f"{role}_TRAFFIC_SECRET_{epochs[-1]}"], 0
        # The newest secret begins at the one record it opens at sequence number 0, found by trying, since a KeyUpdate sent
        # padded shows by no size, and the newest one is mostly near the end.
        start = next((index for index in range(len(kept) - 1, 0, -1) if scanner.open13(found.suite, secret, 0, kept[index][1]) is not None), None)
        for at, record in kept[start:] if start is not None else []:
            plain = scanner.open13(found.suite, secret, seq, record)
            if plain is None:
                break
            seq += 1
            body = plain.rstrip(b"\x00")
            if body[-1:] == b"\x17" and len(body) > 1:
                when = marks[min(bisect.bisect_left(marks, (at + len(record),)), len(marks) - 1)][1]
                out.append((when, from_guest, body[:-1]))
            elif body[-1:] == b"\x16" and body[:1] == b"\x18":
                secret, seq = scanner.next13(found.suite, secret), 0
    return out


def decode(capture, args):
    """A flow's bytes both ways handed to a decoder of the program's own protocol, run inside lab-box, and what it prints."""
    flow = next((f for f in flows(capture, None, args.keys) if f["id"] == args.id), None)
    if flow is None:
        fail(f"there is no flow {args.id}, guest-net flows lists them")
    since = capture.moment(args.since) if args.since else None
    until = capture.moment(args.until) if args.until else None
    taken = [(when, sent, data) for when, sent, data in chunks(capture, flow, args.decrypted, args.keys)
             if (since is None or when >= since) and (until is None or when <= until)]
    given = {"flow": flow["id"], "proto": flow["proto"], "guest": flow["guest"], "remote": flow["remote"], "names": flow["names"],
             "decrypted": args.decrypted, "chunks": [{"time": when, "sent": sent, "data": base64.b64encode(data).decode()} for when, sent, data in taken]}
    if args.save:
        saved(args.save, json.dumps(given).encode())
    if not args.decoder:
        if not args.save:
            fail("decode takes --with SCRIPT, a decoder of the program's protocol, or --save NAME for what one would be given")
        return
    script = os.path.realpath(args.decoder)
    if not os.path.isfile(script):
        fail(f"there is no decoder {args.decoder}")
    command = [shared.SETTINGS.box, "--ro", script, "--", sys.executable, "-I", "-B", script, *args.arguments]
    done = subprocess.run(command, input=json.dumps(given).encode(), capture_output=True, check=False)
    for line in done.stdout.decode("utf-8", "replace").splitlines():
        print(plain(line, 4000))
    if done.returncode != 0:
        for line in done.stderr.decode("utf-8", "replace").splitlines()[-8:]:
            print(plain(line, 400), file=sys.stderr)
        sys.exit(done.returncode)


def trace(capture, args):
    """Arms keys scan --follow and owners --follow, starts the program in the guest as the user, waits for it to end or for
    the time to run out, and shows the flows, requests and handshakes of it and of the programs it started."""
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        fail("trace takes the program to start and its arguments, after --")
    # The program goes by its file's name, in the guest's own way of writing paths.
    name = command[0].replace("\\", "/").rsplit("/", 1)[-1]
    me = [sys.executable, "-I", "-B", os.path.dirname(os.path.abspath(__file__)), *sys.argv[1:9]]
    if args.physical:
        scan_options = ["--physical"]
    else:
        scan_options = ["--process", name, "--children"]
    scan_options += ["--pause"] if args.pause else []
    # Twice a second, since a program just started often holds a connection for only a moment.
    watchers = [subprocess.Popen(me + ["owners", "--follow", "--every", "0.5"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
                subprocess.Popen(me + ["keys", "scan", "--follow", *scan_options], stderr=subprocess.PIPE, text=True, errors="replace")]
    # MemProcFS takes some seconds to open the guest, and the program starts only once the scan follows.
    for line in watchers[1].stderr:
        print(line.rstrip("\n"), file=sys.stderr)
        if "following the capture" in line:
            break
    else:
        fail("keys scan did not begin to follow")
    threading.Thread(target=lambda: [print(line.rstrip("\n"), file=sys.stderr) for line in watchers[1].stderr], daemon=True).start()
    label = f"trace-{time.strftime('%H%M%S')}"
    tell({"do": "mark", "label": label})
    whom = ["--user", args.user] if args.user else [] if args.agent else ["--as-user"]
    started = subprocess.run(["guest-exec", *whom, "--job", *command], capture_output=True, text=True, errors="replace", check=False)
    job = started.stdout.split()[1] if started.returncode == 0 and started.stdout.startswith("job ") else None
    if job is None:
        for watcher in watchers:
            watcher.terminate()
        fail(f"the program did not start: {plain(started.stderr.strip() or started.stdout.strip(), 300)}")
    print(f"guest-net: {name} started as job {job}, marked {label}", file=sys.stderr)
    until = time.monotonic() + args.seconds
    try:
        while time.monotonic() < until:
            status = subprocess.run(["guest-job", "status", job], capture_output=True, text=True, errors="replace", check=False).stdout
            if "running" not in status:
                break
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    # The scan checks what it copied as the last records come in, a moment after the program ended.
    time.sleep(2)
    tell({"do": "mark", "label": label + "-end"})
    for watcher in watchers:
        watcher.send_signal(signal.SIGINT)
    for watcher in watchers:
        try:
            watcher.wait(30)
        except subprocess.TimeoutExpired:
            watcher.kill()
    shown = argparse.Namespace(since=label, until=None, keys=None, process=[name], children=True, host=None, name=None, json=False, max=200, id=None,
                               body=4000, save=None, proto=None, type=None)
    # Read again, for the marks, owners and processes that came while it ran.
    capture = shared.Capture(capture.folder)
    print(f"== flows of {name} and what it started")
    show_flows(capture, shown)
    print("== requests")
    http(capture, shown)
    print("== handshakes")
    tls(capture, shown)


def keys(capture, args):
    """TLS secrets for the capture: added from a key log of this side, pulled from the guest, read from lsass, or listed."""
    if args.action == "schannel":
        schannel.run(capture, args)
        return
    if args.action == "scan":
        chosen = Scope(capture, args)
        found = flows(capture, args)
        # --process also names where to search a flow whose program is not known.
        scan.run(capture, args, chosen.keep(found, unknown=True) if chosen else found, chosen)
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
        # The readers of a stretch of time are those of many flows, which --process and --host narrow as well.
        if timed_too:
            timed(sub)
            scope.arguments(sub)
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
    sub = reader("http", http, "the requests of HTTP/1, HTTP/2 and HTTP/3 and their answers, or one of them in full")
    sub.add_argument("id", nargs="?", help="a request as the list names it, to show its headers and the answer's body")
    sub.add_argument("--save", metavar="NAME", help="write the answer's body to ./out under this name, and the request's as NAME.request")
    sub.add_argument("--body", type=int, default=4000, help="characters of a text body to show, 4000 by default")
    sub.add_argument("--max", type=int, default=300)
    sub.add_argument("--proto", metavar="FOLDER", help="for gRPC: the program's .proto files, to name the fields of its messages")
    sub.add_argument("--type", metavar="MESSAGE", help="for gRPC with --proto: the message type, as package.Message, when its service does not say")
    sub = reader("ws", ws, "the messages of each WebSocket, or of one in full, both ways: text, binary, ping, pong and close, "
                           "fragments put together and undone of permessage-deflate")
    sub.add_argument("id", nargs="?", help="a WebSocket as the list names it: its flow, as t12, or for HTTP/2 and HTTP/3 its request, as h41.3")
    sub.add_argument("--save", metavar="NAME", help="write the messages shown to ./out as NAME, one JSON line each")
    sub.add_argument("--body", type=int, default=2000, help="characters of a message to show, 2000 by default")
    sub.add_argument("--max", type=int, default=200, help="messages to show of each, 200 by default")
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
    sub.add_argument("--process", action="append", metavar="NAME", help="for scan: only flows of this program, by name or number, and "
                                                                         "those whose program is not known, which are searched in it")
    scope.arguments(sub, process=False)
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
    sub = actions.add_parser("decode", help="hand a flow's bytes both ways to a decoder of the program's own protocol, run in the box",
                             description="Hands one flow's chunks both ways, in order, with their times and whether the guest sent each, to a "
                                         "decoder of the program's own protocol: a Python script run inside lab-box that reads them as one JSON "
                                         "object on its standard input, {flow, proto, guest, remote, names, decrypted, chunks: [{time, sent, data "
                                         "in base64}]}, and prints what it makes of them.")
    common(sub)
    timed(sub)
    sub.add_argument("--keys", metavar="FILE", help="a TLS key log of this side, used with the capture's own keys")
    sub.add_argument("id", help="the flow, as t12 or u3")
    sub.add_argument("--with", dest="decoder", metavar="SCRIPT", help="the decoder, a Python script")
    sub.add_argument("--decrypted", action="store_true", help="what went inside TLS, which takes the keys")
    sub.add_argument("--save", metavar="NAME", help="write what a decoder is given to ./out as NAME, to write one against")
    sub.add_argument("arguments", nargs="*", help="arguments for the decoder, after --")
    sub.set_defaults(run=decode)
    sub = actions.add_parser("trace", help="start a program in the guest with keys scan and owners already following, and show its traffic",
                             description="Arms keys scan --follow and owners --follow, starts the program in the guest as the logged in user, waits "
                                         "for it to end or for the time to run out, and shows the flows, requests and handshakes of it and of the "
                                         "programs it started, from the mark it set when it started it.")
    common(sub)
    sub.add_argument("--seconds", type=float, default=60, help="how long to wait for the program to end, 60 by default")
    sub.add_argument("--pause", action="store_true", help="hold the guest still while keys scan copies, as keys scan --pause")
    sub.add_argument("--physical", action="store_true", help="search the whole RAM, for a guest that is not Windows")
    sub.add_argument("--user", metavar="NAME", help="start it as this account instead of the logged in user")
    sub.add_argument("--agent", action="store_true", help="start it as the agent's own account instead of the logged in user")
    sub.add_argument("command", nargs=argparse.REMAINDER, help="-- then the program and its arguments, as guest-exec takes them")
    sub.set_defaults(run=trace)
    sub = reader("export", export, "copy the capture, or a part of it, to ./out, with --decrypted with its TLS secrets in it")
    sub.add_argument("file", nargs="?", help="the name in ./out")
    sub.add_argument("--filter", help="only packets that match this display filter")
    sub.add_argument("--decrypted", action="store_true")
    sub.add_argument("--har", action="store_true", help="the requests of HTTP/1, HTTP/2 and HTTP/3 and their answers as a HAR file instead, "
                                                        "for browser developer tools, Fiddler and other readers of HAR")
    sub = actions.add_parser("tshark", help="run tshark with these options on the capture, in the box", prefix_chars="\0")
    sub.add_argument("arguments", nargs="*")
    sub.set_defaults(run=passthrough, capture=None, keys=None)

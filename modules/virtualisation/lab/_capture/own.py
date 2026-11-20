"""keys own: the keys of a program's own crypto, found in its memory from outside and judged by a decoder of its protocol.

A program that encrypts its traffic in a way of its own keeps the key in its memory while it uses it. No protocol says
how to tell it, so the decoder that reads the program's protocol, the one guest-net decode runs, says it. Asked for
tests, it hands over pieces of the flow's messages, the cipher that opens them and what their plaintext holds, which
libtlsscan tries every window of the program's memory against, millions of them. Asked to judge, it gets the few windows
that passed, with the whole flow, and says which open it. The keys it accepts go to the capture, and decode hands them to
it from then on.
"""
import json
import re
import sys
import time

import capture as shared
import scan
from capture import fail, plain, size, tell

CIPHERS = {"aes-ecb": 1, "aes-cbc": 2, "aes-ctr": 3, "aes-gcm": 4, "chacha20": 5, "chacha20-poly1305": 6, "rc4": 7, "3des-cbc": 8, "salsa20": 9,
           "xsalsa20": 10, "xsalsa20-poly1305": 11, "xchacha20": 12, "xchacha20-poly1305": 13, "tea-ecb": 14, "tea-cbc": 15, "xtea-ecb": 16,
           "xtea-cbc": 17, "blowfish-ecb": 18, "blowfish-cbc": 19}
SIZES = {"aes-ecb": (16, 24, 32), "aes-cbc": (16, 24, 32), "aes-ctr": (16, 24, 32), "aes-gcm": (16, 24, 32), "chacha20": (32,),
         "chacha20-poly1305": (32,), "rc4": tuple(range(1, 65)), "3des-cbc": (24,), "salsa20": (16, 32), "xsalsa20": (32,),
         "xsalsa20-poly1305": (32,), "xchacha20": (32,), "xchacha20-poly1305": (32,), "tea-ecb": (16,), "tea-cbc": (16,), "xtea-ecb": (16,),
         "xtea-cbc": (16,), "blowfish-ecb": tuple(range(4, 57)), "blowfish-cbc": tuple(range(4, 57))}
IVS = {"aes-ecb": 0, "aes-cbc": 16, "aes-ctr": 16, "aes-gcm": 12, "chacha20": 16, "chacha20-poly1305": 12, "rc4": 0, "3des-cbc": 8, "salsa20": 16,
       "xsalsa20": 24, "xsalsa20-poly1305": 24, "xchacha20": 24, "xchacha20-poly1305": 24, "tea-ecb": 0, "tea-cbc": 8, "xtea-ecb": 0, "xtea-cbc": 8,
       "blowfish-ecb": 0, "blowfish-cbc": 8}
BLOCKS = {"aes-ecb": 16, "aes-cbc": 16, "3des-cbc": 8, "tea-ecb": 8, "tea-cbc": 8, "xtea-ecb": 8, "xtea-cbc": 8, "blowfish-ecb": 8, "blowfish-cbc": 8}
AEAD = ("aes-gcm", "chacha20-poly1305", "xsalsa20-poly1305", "xchacha20-poly1305")
# Ciphers whose keys have so many lengths that the decoder names those to try.
NAMED = ("rc4", "blowfish-ecb", "blowfish-cbc")
FIELDS = {"cipher", "key", "data", "iv", "aad", "known", "printable", "span", "padded", "big_endian"}
# As tlsscan takes them: a test's data at most, and how many tests with their key lengths. The decoder judges at most
# JUDGED candidates, those found in the most places first, since a key in use is mostly in several.
LONGEST, MOST_TESTS, JUDGED = 1 << 16, 64, 256
# How far from a key's first byte its IV may be read.
BESIDE = 4096
HEX = re.compile(r"(?:[0-9a-fA-F]{2})*")


class Unfit(Exception):
    """What is wrong with the tests a decoder set."""


class Test:
    """One test a decoder set, for keys of one length."""

    def __init__(self, number, name, keylen, data, iv, beside, aad, known, mask, knownat, printable, span, padded, big_endian):
        self.number, self.name, self.keylen = number, name, keylen
        self.cipher, self.ivlen = CIPHERS[name], IVS[name]
        self.data, self.iv, self.beside, self.aad = data, iv, beside, aad
        self.known, self.mask, self.knownat = known, mask, knownat
        self.printable, self.span, self.padded, self.big_endian = printable, span, padded, big_endian

    @property
    def label(self):
        """The cipher with the size of its key where AES has several, and the order of TEA's words where they are big endian,
        as aes-256-cbc or xtea-cbc-be."""
        if self.name.startswith("aes-"):
            return f"aes-{self.keylen * 8}-{self.name[4:]}"
        return self.name + ("-be" if self.big_endian else "")


def hexed(value, where, field, empty=True):
    if not isinstance(value, str) or not HEX.fullmatch(value) or (not empty and not value) or len(value) > 2 * LONGEST:
        raise Unfit(f"{where}: {field} is {'' if empty else 'some '}bytes written in hex, at most {LONGEST}")
    return bytes.fromhex(value)


def whole(value, where, field, low=0, high=LONGEST):
    if type(value) is not int or not low <= value <= high:
        raise Unfit(f"{where}: {field} is a whole number from {low} to {high}")
    return value


def tests_from(answer):
    """The tests in a decoder's answer, one Test for each length of key. Unfit says what is wrong with them."""
    if not isinstance(answer, dict) or not isinstance(answer.get("tests"), list) or not answer["tests"]:
        raise Unfit('the answer is not {"tests": [...]} with a test in it')
    out = []
    for number, spec in enumerate(answer["tests"]):
        where = f"test {number}"
        if not isinstance(spec, dict):
            raise Unfit(f"{where} is no object")
        if set(spec) - FIELDS:
            raise Unfit(f"{where} has fields a test has not: {plain(', '.join(sorted(map(str, set(spec) - FIELDS))), 200)}")
        name = spec.get("cipher")
        if name not in CIPHERS:
            raise Unfit(f"{where}: cipher is one of {', '.join(CIPHERS)}")
        allowed = SIZES[name]
        sizes = spec.get("key", None if name in NAMED else list(allowed))
        sizes = [sizes] if type(sizes) is int else sizes
        if not isinstance(sizes, list) or not sizes or not all(type(s) is int and s in allowed for s in sizes):
            told = f"{allowed[0]} to {allowed[-1]}" if name in NAMED else ", ".join(map(str, allowed))
            raise Unfit(f"{where}: key is the length of a {name} key in bytes, or a list of them, of {told}")
        data = hexed(spec.get("data"), where, "data", empty=False)
        aead = name in AEAD
        body = len(data) - (16 if aead else 0)
        if body <= 0:
            raise Unfit(f"{where}: the data of {name} has its tag of 16 bytes and more")
        if name in BLOCKS and len(data) % BLOCKS[name]:
            raise Unfit(f"{where}: the data of {name} is whole blocks of {BLOCKS[name]} bytes")
        iv, beside = b"", None
        if IVS[name]:
            given = spec.get("iv")
            if isinstance(given, dict) and set(given) == {"beside"}:
                beside = whole(given["beside"], where, "iv's beside", -BESIDE, BESIDE)
            else:
                iv = hexed(given, where, "iv")
                if len(iv) != IVS[name]:
                    raise Unfit(f'{where}: the iv of {name} is {IVS[name]} bytes, or {{"beside": OFFSET}} from the key\'s first byte in memory')
        elif "iv" in spec:
            raise Unfit(f"{where}: {name} takes no iv")
        aad = hexed(spec.get("aad", ""), where, "aad")
        if aad and (not aead or name == "xsalsa20-poly1305"):
            raise Unfit(f"{where}: only {', '.join(a for a in AEAD if a != 'xsalsa20-poly1305')} take aad")
        known, mask, knownat = b"", b"", 0
        if "known" in spec:
            given = spec["known"]
            if not isinstance(given, dict) or not set(given) <= {"at", "bytes", "mask"}:
                raise Unfit(f"{where}: known is {{at, bytes, mask}}")
            knownat = whole(given.get("at", 0), where, "known's at")
            known = hexed(given.get("bytes"), where, "known's bytes", empty=False)
            mask = hexed(given.get("mask", "ff" * len(known)), where, "known's mask")
            if len(mask) != len(known):
                raise Unfit(f"{where}: known's mask is as long as its bytes")
            if knownat + len(known) > body:
                raise Unfit(f"{where}: known goes past the end of the plaintext")
        printable = whole(spec.get("printable", 0), where, "printable")
        span = whole(spec.get("span", min(body, 64) if printable else 0), where, "span", 0, body)
        if printable > span:
            raise Unfit(f"{where}: printable is at most span, the bytes it counts in")
        padded = spec.get("padded", False)
        if type(padded) is not bool or (padded and name not in BLOCKS):
            raise Unfit(f"{where}: padded is true or false, and only for {', '.join(BLOCKS)}")
        big_endian = spec.get("big_endian", False)
        if type(big_endian) is not bool or (big_endian and not name.startswith(("tea-", "xtea-"))):
            raise Unfit(f"{where}: big_endian is true or false, and only for TEA and XTEA")
        if not (known or printable or padded or aead):
            raise Unfit(f"{where} checks nothing, so every window would pass it: give known, printable or padded, or use an AEAD's tag")
        out += [Test(number, name, keylen, data, iv, beside, aad, known, mask, knownat, printable, span, padded, big_endian) for keylen in sizes]
    if len(out) > MOST_TESTS:
        raise Unfit(f"the tests come to {len(out)} with their lengths of key, and at most {MOST_TESTS} are tried at once")
    return out


def ask(script, given, what, **extra):
    """A decoder's answer to a question, which is one JSON object on its standard output."""
    done = shared.run_decoder(script, {**given, "ask": what, **extra})
    if done.returncode != 0:
        for line in done.stderr.decode("utf-8", "replace").splitlines()[-8:]:
            print(plain(line, 400), file=sys.stderr)
        fail(f"the decoder failed when asked to {what}")
    try:
        return json.loads(done.stdout)
    except ValueError:
        fail(f"the decoder's answer to {what} is not one JSON object: {plain(done.stdout.decode('utf-8', 'replace').strip(), 200)}")


def run(capture, args, given, flow):
    if not args.decoder:
        fail("own takes --with SCRIPT, the decoder of the program's protocol, which sets the tests and judges what passes them")
    try:
        tests = tests_from(ask(args.decoder, given, "tests"))
    except Unfit as e:
        fail(f"the decoder's tests: {e}")
    sources = scan.program_sources(flow, args, args.all)
    if not sources:
        fail(f"{flow['id']}: its program is not known, owners --follow while it runs finds it, or --process names it")
    scanner, found, kept, searched = scan.Scanner(shared.SETTINGS.scan), {}, True, 0
    for source in sources:
        try:
            regions = list(source.regions(args.max_memory << 20))
        except LookupError as e:
            print(f"guest-net: {source}: {e}", file=sys.stderr)
            continue
        searched += 1
        total = sum(length for _, _, length in regions)
        step, started, before = scan.step_for(args, total), time.monotonic(), len(found)
        print(f"guest-net: {source}: {size(total)} to try at step {step} against {len(tests)} tests", file=sys.stderr)
        for start, buffer, length in regions:
            hits, count = scanner.own(buffer, length, start, tests, step, scan.threads())
            kept &= count == len(hits)
            for index, key, iv, place in hits:
                test = tests[index]
                # An IV the decoder gave is its own to know, one read beside the key is part of what was found.
                where = found.setdefault((test.number, test.label, key, iv if test.beside is not None else b""), (str(source), []))
                where[1].append(place)
        print(f"guest-net: {scanner.tested} keys tried in {time.monotonic() - started:.1f} s, {len(found) - before} passed", file=sys.stderr)
    if not searched:
        fail(f"{flow['id']}: no memory of its program could be read")
    if not kept:
        print("guest-net: so many windows passed that only the first were kept: make the tests stricter", file=sys.stderr)
    if not found:
        print(f"{flow['id']}: no window of the program's memory passed the tests")
        return
    if len(found) > JUDGED:
        print(f"guest-net: {len(found)} keys passed, and the decoder judges the {JUDGED} found in the most places: make the tests stricter", file=sys.stderr)
    ordered = sorted(found.items(), key=lambda item: -len(item[1][1]))[:JUDGED]
    listed = [{"index": i, "test": number, "cipher": label, "key": key.hex(), "iv": iv.hex(), "places": [f"{p:#x}" for p in sorted(places)[:16]],
               "found": len(places), "process": where} for i, ((number, label, key, iv), (where, places)) in enumerate(ordered)]
    verdict = ask(args.decoder, given, "judge", candidates=listed)
    accepted = verdict.get("accepted") if isinstance(verdict, dict) else None
    if not isinstance(accepted, list) or not all(type(i) is int and 0 <= i < len(listed) for i in accepted):
        fail('the decoder\'s judgement is not {"accepted": [index, ...]} of the candidates it was given')
    entries = []
    for i in sorted(set(accepted)):
        c = listed[i]
        entries.append({"flow": flow["id"], "cipher": c["cipher"], "key": c["key"], "iv": c["iv"], "address": c["places"][0],
                        "process": plain(c["process"], 200)})
        more = f" and {c['found'] - 1} more" if c["found"] > 1 else ""
        print(f"{flow['id']:<6} {c['cipher']}  key {c['key']}" + (f"  iv {c['iv']}" if c["iv"] else "") + f"  at {c['places'][0]}{more}  in {c['process']}")
    if entries:
        tell({"do": "note", "kind": "own", "entries": entries}, needed=False)
    print(f"guest-net: {len(entries)} of {len(listed)} candidates the decoder judged to open the flow", file=sys.stderr)

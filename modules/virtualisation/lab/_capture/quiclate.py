"""QUIC after key updates, opened by guest-net itself. tshark opens a QUIC connection only from its first traffic secrets
on, which a program no longer holds once it updated its keys, and keys scan finds the newer ones. Without the key of the
headers' protection, which only the first secret gives, a short packet is opened by trying what that key hides, as keys
scan does, with its packet number near the one before. Each later update met on the way turns the secret into the next,
and the stream data of what opens goes to h3.py.

The guest's own packets are all in the capture, so their numbers run on but for those its program skipped. Those of the
other side lack the ones lost on the way, which the guest's acknowledgements tell, so the guest's side is opened first."""
import bisect

from tlsrecords import quic_packets, quic_short_packets, varint

# How far from where it is expected a packet's number is looked for: NEAR past the one before, for numbers a sender skipped
# and packets lost between two, FAR where nothing is known yet. A secret is looked for among the last BACK packets, and so
# is the one after it, for an update after keys scan found it.
NEAR, FAR, BACK = 16, 256, 4096
# Frames of RFC 9000 19 and of ACK_FREQUENCY that are only so many variable length integers, by type.
NUMBERS = {0x04: 3, 0x05: 2, 0x10: 1, 0x11: 2, 0x12: 1, 0x13: 1, 0x14: 1, 0x15: 2, 0x16: 1, 0x17: 1, 0x19: 1, 0xAF: 4}


def frames(plain):
    """The frames of a packet's plaintext, as ("stream", id, offset, data, fin) and ("ack", the largest acknowledged), the
    others stepped over, up to the first this does not know or that does not fit."""
    found, at = [], 0
    try:
        while at < len(plain):
            kind, at = varint(plain, at)
            if kind in (0x00, 0x01, 0x1E, 0x1F):
                continue
            if kind in (0x02, 0x03):
                largest, at = varint(plain, at)
                _, at = varint(plain, at)
                ranges, at = varint(plain, at)
                # The first range, then a gap and a length for each more, then three counts of ECN with type 0x03.
                for _ in range(1 + 2 * ranges + (3 if kind == 0x03 else 0)):
                    _, at = varint(plain, at)
                found.append(("ack", largest))
            elif 0x08 <= kind <= 0x0F:
                stream, at = varint(plain, at)
                offset, at = varint(plain, at) if kind & 0x04 else (0, at)
                length, at = varint(plain, at) if kind & 0x02 else (len(plain) - at, at)
                if at + length > len(plain):
                    break
                found.append(("stream", stream, offset, plain[at: at + length], bool(kind & 0x01)))
                at += length
            elif kind in NUMBERS:
                for _ in range(NUMBERS[kind]):
                    _, at = varint(plain, at)
            elif kind in (0x06, 0x1C, 0x1D):
                # CRYPTO's offset, CONNECTION_CLOSE's error and the type of frame that caused it, then a length and as many bytes.
                for _ in range({0x06: 1, 0x1C: 2, 0x1D: 1}[kind]):
                    _, at = varint(plain, at)
                length, at = varint(plain, at)
                at += length
            elif kind in (0x07, 0x31):
                length, at = varint(plain, at)
                at += length
            elif kind == 0x18:
                _, at = varint(plain, at)
                _, at = varint(plain, at)
                at += 1 + plain[at] + 16
            elif kind in (0x1A, 0x1B):
                at += 8
            elif kind == 0x30:
                at = len(plain)
            else:
                break
    except IndexError:
        pass
    return found


class Side:
    """The short packets one side sent, in order, each as (where it is among both sides' packets, the least number it can
    have, where its number starts, the packet, what came with its datagram), and those that opened: {index: (packet
    number, plaintext)}."""

    def __init__(self, scanner, version, suite, packets):
        self.scanner, self.version, self.suite, self.packets, self.opened, self.missed = scanner, version, suite, packets, {}, 0

    def attempt(self, secret, index, low, high, any_frame=True):
        """The packet at this index opened with the secret at a number from low up to high, as (plaintext, key phase,
        number), or None."""
        _, lowest, at, packet, _ = self.packets[index]
        low = max(low, lowest)
        return self.scanner.quic_late(self.version, self.suite, secret, packet, at, low, high - low, any_frame) if high > low else None

    def anchor(self, chain, hints):
        """The latest packet a secret of the chain opens, as (index, which of the chain, number, plaintext): where the other
        side's acknowledgements put one, then from the last packet back."""
        for index, number in hints:
            for level, secret in enumerate(chain):
                opened = self.attempt(secret, index, number - NEAR, number + NEAR)
                if opened:
                    return index, level, opened[2], opened[0]
        for index in range(len(self.packets) - 1, max(len(self.packets) - 1 - BACK, -1), -1):
            for level, secret in enumerate(chain):
                opened = self.attempt(secret, index, 0, self.packets[index][1] + FAR, False)
                if opened:
                    return index, level, opened[2], opened[0]
        return None

    def back(self, chain, level, index, number):
        """The packets before this one the chain opens, each number below the one after it, under the secret of the packet
        after it or the one before that secret, back to where the chain's first began, as {index: (number, plaintext)}."""
        found = {}
        while index > 0:
            for down in range(level, max(level - 2, -1), -1):
                opened = self.attempt(chain[down], index - 1, number - NEAR, number)
                if opened:
                    level = down
                    break
            else:
                break
            index, number = index - 1, opened[2]
            found[index] = (number, opened[0])
        return found

    def read(self, secrets, hints=()):
        """Opens what the secrets open: from the first packet of the oldest keys one of them opens, on to the end, each
        later update followed."""
        best = None
        for secret in secrets:
            chain = [secret, self.scanner.quic_next(self.version, self.suite, secret)]
            found = self.anchor(chain, hints)
            if found is None:
                continue
            index, level, number, plain = found
            earlier = self.back(chain, level, index, number)
            start = min(earlier, default=index)
            if best is None or start < best[0]:
                best = (start, chain[level], index, number, {index: (number, plain), **earlier})
        if best is None:
            return
        _, current, anchor, number, self.opened = best
        following, expected = None, number + 1
        for index in range(anchor + 1, len(self.packets)):
            # Near the number expected under the keys of the packet before, or under the next ones, then one that came
            # late, then far, past a run of packets lost on the way.
            for later, low, high, any_frame in ((False, expected, expected + NEAR, True), (True, expected, expected + NEAR, True),
                                                (False, expected - NEAR, expected, True), (False, expected, expected + FAR, False),
                                                (True, expected, expected + FAR, False)):
                if later:
                    following = following or self.scanner.quic_next(self.version, self.suite, current)
                opened = self.attempt(following if later else current, index, low, high, any_frame)
                if opened:
                    if later:
                        current, following = following, None
                    break
            else:
                self.missed += 1
                expected += 1
                continue
            plain, _, number = opened
            self.opened[index] = (number, plain)
            expected = max(expected, number + 1)


def version_of(datagrams):
    """The QUIC version of a connection's first long header, 1 or 2, or None."""
    for _, datagram, *_ in datagrams:
        for _, version, *_ in quic_packets(datagram, None):
            if version:
                return version
    return None


def split(datagrams):
    """The short packets of each side of a connection's datagrams in order, {side: [(where it is among both sides' packets,
    the least number it can have, where its number starts, the packet, what else came with its datagram)]}."""
    parts = {0: [], 1: []}
    for place, (side, lowest, at, packet, extra) in enumerate(quic_short_packets(datagrams)):
        parts[side].append((place, lowest, at, packet, extra))
    return parts


def read(scanner, suite, secrets, datagrams, guest_side):
    """The stream data of a QUIC connection after its key updates, as h3.py takes it: [(time, frame number, 0 from the client
    or 1 from the server, stream, offset, data, fin)], with how many packets after the first that opened did not.
    secrets are those keys scan found, {side: [secret]}, datagrams (side, payload, time, frame number) in order, and
    guest_side the side the guest is."""
    version = version_of(datagrams)
    if version is None:
        return [], 0
    parts, sides = split(datagrams), {}
    for side in sorted((0, 1), key=lambda side: side != guest_side):
        sides[side] = Side(scanner, version, suite, parts[side])
        sides[side].read(secrets.get(side, []), hints(sides.get(1 - side), parts[side]))
    events = []
    for side, opened in sides.items():
        for index, (_, plain) in opened.opened.items():
            when, number = opened.packets[index][4]
            for frame in frames(plain):
                if frame[0] == "stream":
                    events.append((float(when), int(number), side, *frame[1:]))
    events.sort(key=lambda event: (event[0], event[1]))
    return events, sum(side.missed for side in sides.values())


def hints(other, own):
    """Where the other side's acknowledgements put this side's packets, latest first, as (index, number): the largest number
    one acknowledges is that of the last packet this side sent before it, give or take one that came late."""
    if other is None:
        return []
    places = [place for place, *_ in own]
    found = []
    for index, (_, plain) in sorted(other.opened.items(), reverse=True):
        acknowledged = [frame[1] for frame in frames(plain) if frame[0] == "ack"]
        if acknowledged:
            before = bisect.bisect_left(places, other.packets[index][0])
            if before:
                found.append((before - 1, max(acknowledged)))
        if len(found) >= 8:
            break
    return found

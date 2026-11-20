"""--process, --children and --host of guest-net's readers: which flows a reader keeps, by the program each belonged to and by
the names and addresses it went to.

A flow's program is what owners recorded while it lasted, and which program started which is what owners and keys scan
--follow recorded of the guest's processes. --process leaves out flows whose program is not known.
"""
import ipaddress
import sys

import owners


def arguments(parser, *, process=True):
    if process:
        parser.add_argument("--process", action="append", metavar="NAME",
                            help="only flows of this program, by name or number, more than once for several")
    parser.add_argument("--children", action="store_true", help="with --process: also the flows of the programs it started, and of theirs")
    parser.add_argument("--host", action="append", metavar="NAME",
                        help="only flows to this name or a name under it, or to this address or network, as 10.0.0.0/8, more than once for several")


def bare(name):
    """A program's name as the guest's own tools and its memory may each give it, ending in .exe or not."""
    return str(name).lower().removesuffix(".exe")


class Scope:
    def __init__(self, capture, args):
        asked = getattr(args, "process", None) or []
        self.names = {bare(n) for n in asked if not n.isdigit()}
        self.numbers = {int(n) for n in asked if n.isdigit()}
        self.children = bool(getattr(args, "children", False))
        self.networks, self.domains = [], []
        for host in getattr(args, "host", None) or []:
            try:
                self.networks.append(ipaddress.ip_network(host.strip("[]"), strict=False))
            except ValueError:
                self.domains.append(host.lower().strip("."))
        self.pids = self.resolve(capture) if self.processes else set()

    @property
    def processes(self):
        return bool(self.names or self.numbers)

    def __bool__(self):
        return self.processes or bool(self.networks or self.domains)

    def resolve(self, capture):
        """The numbers of the programs asked for, as the capture knows them, and with --children of those they started."""
        seen = list(capture.lines("processes.jsonl")) + owners.known(capture) if capture else []
        pids, started = set(self.numbers), {}
        for entry in seen:
            pid = entry.get("pid")
            if type(pid) is not int:
                continue
            if bare(entry.get("process", "")) in self.names:
                pids.add(pid)
            parent = entry.get("ppid")
            if type(parent) is int and parent != pid:
                started.setdefault(parent, set()).add(pid)
        if self.children:
            todo = list(pids)
            while todo:
                for child in started.get(todo.pop(), ()):
                    if child not in pids:
                        pids.add(child)
                        todo.append(child)
        return pids

    def host(self, names, address):
        """Whether one of the names, or the address, is one --host asked for. True when it asked for none."""
        if not (self.networks or self.domains):
            return True
        for name in names:
            name = str(name).lower().strip(".")
            if any(name == domain or name.endswith("." + domain) for domain in self.domains):
                return True
        try:
            parsed = ipaddress.ip_address(str(address).strip("[]"))
        except ValueError:
            return False
        return any(parsed in network for network in self.networks)

    def wanted(self, flow, unknown=False):
        """Whether a reader keeps the flow. With unknown, a flow whose program is not known passes --process."""
        if self.processes and not (flow.get("pid") in self.pids or (unknown and flow.get("pid") is None)):
            return False
        return self.host(flow["names"], flow["address"])

    def covers(self, pid, name, parent_of):
        """Whether a running process is one asked for, for keys scan --follow, which meets programs the capture has not
        recorded yet. parent_of gives a process's parent's number and name, or (None, "")."""
        if not self.processes:
            return True
        seen = set()
        while pid and pid not in seen:
            seen.add(pid)
            if pid in self.numbers or pid in self.pids or bare(name) in self.names:
                return True
            if not self.children:
                return False
            pid, name = parent_of(pid)
        return False

    def keep(self, found, unknown=False):
        """The flows kept, saying on stderr how many --process left out for want of their program."""
        kept = [flow for flow in found if self.wanted(flow, unknown)]
        missing = sum(1 for flow in found if flow.get("pid") is None and self.host(flow["names"], flow["address"]))
        if self.processes and not unknown and missing:
            print(f"guest-net: {missing} flows whose program is not known are left out, owners --follow while they last finds it",
                  file=sys.stderr)
        return kept

    @staticmethod
    def display(kept):
        """The display filter for the packets of the flows kept."""
        parts = []
        for proto, letter in (("tcp", "t"), ("udp", "u")):
            numbers = sorted(int(flow["id"][1:]) for flow in kept if flow["id"][0] == letter)
            if numbers:
                parts.append(f"{proto}.stream in {{{', '.join(map(str, numbers))}}}")
        return " || ".join(parts) or "frame.number == 0"

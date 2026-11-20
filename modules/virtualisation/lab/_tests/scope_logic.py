"""Which flows --process, --children and --host keep: programs by name as memory and the guest's tools each give it or by
number, the programs they started from what the capture recorded, hosts by name and the names under it, by address and by
network, and the display filter that keeps the packets of the flows kept. Started with the folder of guest-net's code."""
import argparse
import contextlib
import io
import sys

sys.path.insert(0, sys.argv[1])
import scope


class Capture:
    def __init__(self, processes, owners):
        self.files = {"processes.jsonl": processes, "owners.jsonl": owners}

    def lines(self, name):
        return iter(self.files.get(name, []))


def parse(*words):
    parser = argparse.ArgumentParser()
    scope.arguments(parser)
    return parser.parse_args(list(words))


# explorer started the sample, which started cmd, which started curl. explorer also started another program, and one
# process names itself as its parent while two others name each other.
processes = [
    {"pid": 100, "ppid": 4, "process": "explorer.exe"},
    {"pid": 200, "ppid": 100, "process": "sample.exe"},
    {"pid": 300, "ppid": 200, "process": "cmd.exe"},
    {"pid": 400, "ppid": 300, "process": "curl.exe"},
    {"pid": 500, "ppid": 100, "process": "other.exe"},
    {"pid": 600, "ppid": 600, "process": "self.exe"},
    {"pid": 700, "ppid": 701, "process": "loop.exe"},
    {"pid": 701, "ppid": 700, "process": "loop.exe"},
]
owners = [{"proto": "tcp", "local": "10.0.0.5:5000", "remote": "1.2.3.4:443", "pid": 3360, "process": "msedge"}]
capture = Capture(processes, owners)

assert scope.Scope(capture, parse("--process", "SAMPLE")).pids == {200}
assert scope.Scope(capture, parse("--process", "sample", "--children")).pids == {200, 300, 400}
assert scope.Scope(capture, parse("--process", "200", "--children")).pids == {200, 300, 400}
assert scope.Scope(capture, parse("--process", "msedge.exe")).pids == {3360}, "a name with .exe has to find the agent's name without it"
assert scope.Scope(capture, parse("--process", "self", "--children")).pids == {600}
assert scope.Scope(capture, parse("--process", "loop", "--children")).pids == {700, 701}
assert scope.Scope(capture, parse("--process", "nothing")).pids == set()
assert not scope.Scope(capture, parse()), "no option has to keep everything"

flows = [
    {"id": "t1", "names": ["api.example.com"], "address": "93.184.216.34", "pid": 400},
    {"id": "t5", "names": ["example.com."], "address": "93.184.216.34", "pid": 500},
    {"id": "u2", "names": ["badexample.com"], "address": "10.9.9.1", "pid": 200},
    {"id": "t7", "names": [], "address": "2001:db8::1", "pid": None},
]


def kept(*words, unknown=False):
    chosen = scope.Scope(capture, parse(*words))
    with contextlib.redirect_stderr(io.StringIO()) as said:
        out = [flow["id"] for flow in chosen.keep(flows, unknown)]
    return out, said.getvalue()


assert kept("--host", "example.com")[0] == ["t1", "t5"], "a name and those under it, and nothing that only ends alike"
assert kept("--host", "EXAMPLE.COM.")[0] == ["t1", "t5"]
assert kept("--host", "10.9.9.1")[0] == ["u2"]
assert kept("--host", "10.0.0.0/8")[0] == ["u2"]
assert kept("--host", "[2001:db8::1]")[0] == ["t7"]
assert kept("--host", "2001:db8::/32", "--host", "10.9.9.1")[0] == ["u2", "t7"]
assert kept("--process", "sample", "--children")[0] == ["t1", "u2"]
assert kept("--process", "sample", "--children", "--host", "example.com")[0] == ["t1"], "both options have to hold"
out, said = kept("--process", "sample")
assert out == ["u2"] and "1 flows whose program is not known are left out" in said, (out, said)
out, said = kept("--process", "sample", unknown=True)
assert out == ["u2", "t7"] and not said, (out, said)

assert scope.Scope.display([flows[0], flows[1], flows[2]]) == "tcp.stream in {1, 5} || udp.stream in {2}"
assert scope.Scope.display([]) == "frame.number == 0", "no flow kept has to keep no packet"

# keys scan --follow meets programs the capture has not recorded, and asks the guest's memory for their parents.
live = {900: (100, "explorer.exe"), 901: (900, "sample.exe"), 902: (901, "helper.exe"), 100: (4, "explorer.exe")}


def parent_of(pid):
    parent = live.get(pid, (None, ""))[0]
    return (parent, live[parent][1]) if parent in live else (None, "")


chosen = scope.Scope(capture, parse("--process", "sample", "--children"))
assert chosen.covers(902, "helper.exe", parent_of), "a child that only memory knows has to be covered through its parent"
assert chosen.covers(901, "sample.exe", parent_of)
assert not chosen.covers(900, "explorer.exe", parent_of), "the program that started the one asked for is not covered"
assert not scope.Scope(capture, parse("--process", "sample")).covers(902, "helper.exe", parent_of), "without --children only the program itself"
assert scope.Scope(capture, parse()).covers(1, "anything", parent_of)
print("scope keeps the programs and hosts asked for, and nothing else")

# nix build --no-link -L .#tests.lab.guest-dbg
# guest-dbg against a real guest, on the machine the tests of a session share, with a shell in that guest stopped from outside.
{
  host,
}:

let
  inherit (host) pkgs;
in
host.needs [ "modules/virtualisation/inspect" ] (
  import ../../inspect/_tests/fixture.nix { inherit host; } {
    name = "guest-dbg";
    tools = inspect: [ (pkgs.callPackage ../_guest-dbg/guest-dbg.nix { inherit (inspect) memprocfs; }) ];

    testScript = ''
      start_driven()

      with subtest("guest-dbg stops one process of the guest from outside and lets every other one go"):
          # A shell whose builtin umask is a system call that only it makes, and which tells its old mask on return.
          out = machine.succeed(session("--gdb --control", "; ".join([
              "symbol() { guest-exec --shell \"grep -E ' [TtDdBb] $1\\$' /proc/kallsyms | cut -d' ' -f1\" 2>/dev/null | head -n 1; }",
              "umask=0x$(symbol __x64_sys_umask); jiffies=0x$(symbol jiffies); echo umask=$umask jiffies=$jiffies",
              "job=$(guest-exec --job --shell 'while :; do umask 022; sleep 0.2; done' | cut -d' ' -f2)",
              "root=$(guest-dbg - --break $umask --timeout 30 2>/dev/null | grep -o 'cr3=0x[0-9a-f]*' | head -n 1 | cut -d= -f2); echo root=$root",
              "guest-dbg cr3=$root --break $umask --hits 2 --timeout 30 --on-return 'p/x $rax' 2>&1; echo own=$?",
              "guest-dbg cr3=0x1000 --break $umask --timeout 3 2>&1; echo other=$?",
              "guest-dbg - --watch $jiffies:8 --timeout 30 --do 'p/x $rip' 2>&1; echo watched=$?",
              "guest-dbg - --break $umask --break $umask --break $umask --break $umask --on-return 'p 1' 2>&1; echo many=$?",
              "guest-job stop $job > /dev/null; guest-exec true 2>&1; echo alive=$?",
          ])))
          print(out)
          assert re.search(r"^root=0x[0-9a-f]+$", out, re.MULTILINE), out
          # The builtin asks the old mask with umask(0) before it sets the new one, so its calls return 022 and 0 by turns.
          own = out.split("root=")[1].split("own=")[0]
          assert own.count("returned to") == 2 and re.search(r"\$\d = 0x12", own) and re.search(r"\$\d = 0x0", own), f"the returns were not seen: {own}"
          assert "hit 2: break" in own and "own=0" in out, out
          other = out.split("own=0")[1].split("other=")[0]
          assert "0 of 1 stops in the process" in other and "other=1" in out, f"a stop in another process was taken: {other}"
          assert not re.search(r"0 of 1 stops in the process, 0 elsewhere", other), f"nothing else ran through the place: {other}"
          assert "hit 1: watch" in out and re.search(r"old \d+, new \d+", out) and "watched=0" in out, out
          assert "takes 5 debug registers" in out and "many=1" in out, out
          assert "alive=0" in out, out

      with subtest("guest-dbg --log writes what a function of the process was given, and at its return what it gave back"):
          machine.succeed("install -d -o alice /tmp/work/out")
          out = machine.succeed(session("--gdb --control", "; ".join([
              "symbol() { guest-exec --shell \"grep -E ' [TtDdBb] $1\\$' /proc/kallsyms | cut -d' ' -f1\" 2>/dev/null | head -n 1; }",
              "umask=0x$(symbol __x64_sys_umask); write=0x$(symbol vfs_write); read=0x$(symbol vfs_read); echo write=$write read=$read",
              "guest-exec --shell 'printf hello > /tmp/word' > /dev/null",
              "job=$(guest-exec --job --shell 'while :; do umask 022; echo secret-line > /dev/null; read -n 5 x < /tmp/word; sleep 0.2; done' | cut -d' ' -f2)",
              "root=$(guest-dbg - --break $umask --timeout 30 2>/dev/null | grep -o 'cr3=0x[0-9a-f]*' | head -n 1 | cut -d= -f2)",
              "cd /tmp/work",
              "guest-dbg cr3=$root --log $write,rsi,rdx --hits 2 --out writes --timeout 30 2>&1; echo written=$?",
              "guest-dbg cr3=$root --log $read,rsi,ret@return --hits 10 --out reads --timeout 30 2>&1; echo was_read=$?",
              "echo == first; cat out/writes/00001-*.bin",
              "echo == reads; cat out/reads/*.bin; echo",
              "echo == index; cat out/writes/index.jsonl",
              "guest-job stop $job > /dev/null; guest-exec true 2>&1; echo alive=$?",
          ])))
          print(out)
          assert "written=0" in out and "was_read=0" in out and "alive=0" in out, out
          assert "out/writes" in out and re.search(r"log 2: 0x[0-9a-f]+ 12 B, cpu \S+, 00002-0x[0-9a-f]+\.bin  secret-line", out), out
          assert out.split("== first")[1].split("== reads")[0].strip() == "secret-line", "what echo wrote was not the buffer written"
          # Ten bytes of a shell that reads the five of hello over and over have the word whole among them.
          assert "hello" in out.split("== reads")[1].split("== index")[0], "what read gave back was not the buffer written at its return"
          assert '"length": 12' in out.split("== index")[1], out

      with subtest("guest-dbg --resume lets a program held before its first instruction run once its stops are set"):
          out = machine.succeed(session("--gdb --control", "; ".join([
              "symbol() { guest-exec --shell \"grep -E ' [TtDdBb] $1\\$' /proc/kallsyms | cut -d' ' -f1\" 2>/dev/null | head -n 1; }",
              "umask=0x$(symbol __x64_sys_umask)",
              "said=$(guest-exec --job --suspended --shell 'umask 022; echo ran'); job=$(echo \"$said\" | grep -o 'job [0-9a-f]*' | head -n 1 | cut -d' ' -f2)",
              "sleep 2; echo == before; guest-job status $job",
              "echo == dbg; guest-dbg - --break $umask --resume $job --timeout 30 2>&1; echo resumed=$?",
              "sleep 2; echo == after; guest-job status $job",
              "guest-dbg - --break $umask --resume 'x;y' 2>&1; echo refused=$?",
          ])))
          print(out)
          # A held program's process is there, stopped, so its job is running until it was let run and ended.
          assert re.search(r"^[0-9a-f]+  running$", out.split("== before")[1].split("== dbg")[0], re.MULTILINE), "the program ran before it was let"
          dbg = out.split("== dbg")[1].split("== after")[0]
          assert re.search(r"guest-dbg: job [0-9a-f]+ runs", dbg) and "hit 1: break" in dbg and "resumed=0" in dbg, dbg
          assert re.search(r"^[0-9a-f]+  exit 0$", out.split("== after")[1], re.MULTILINE), out
          assert "--resume takes the name of a job" in out and "refused=2" in out, out
    '';
  }
)

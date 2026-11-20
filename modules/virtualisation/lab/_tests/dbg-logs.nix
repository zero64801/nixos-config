# nix build --no-link -L .#tests.lab.dbg-logs
# guest-dbg --log on made up registers and memory: the presets' buffers, WSABUF arrays, SecBuffers, error lengths, the limit and the files written.
{
  host,
}:

host.pkgs.runCommand "guest-dbg-logs" { nativeBuildInputs = [ host.pkgs.python3 ]; } ''
  python3 -I -B ${./dbg_logs_logic.py} ${../_guest-dbg}
  touch $out
''

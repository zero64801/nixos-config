{
  runCommand,
  writeShellScriptBin,
  python3,
}:

library:

let
  # Beside the modules it is made of, so that it finds them the way they find each other, and started with its name first as they are.
  source = runCommand "vm-inspect-guest-mcp" { } ''
    cp -r ${library} $out
    chmod -R u+w $out
    cp ${./_mcp.py} $out/__main__.py
  '';
in
writeShellScriptBin "guest-mcp" ''
  exec ${python3}/bin/python3 -I -B ${source} mcp "$@"
''

{
  writeShellScriptBin,
  python3,
  gdb,
  memprocfs,
}:

let
  python = python3.withPackages (packages: [ packages.dnfile ]);
in
writeShellScriptBin "guest-dbg" ''
  exec ${python}/bin/python3 -I -B ${./.} ${gdb}/bin/gdb ${memprocfs}/lib/memprocfs/vmm.so "$@"
''

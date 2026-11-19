{
  writeShellScriptBin,
  python3,
  gdb,
  memprocfs,
}:

writeShellScriptBin "guest-dbg" ''
  exec ${python3}/bin/python3 -I -B ${./.} ${gdb}/bin/gdb ${memprocfs}/lib/memprocfs/vmm.so "$@"
''

# guest-net and guest-usb, which read what a session recorded of its guest, with tshark inside lab-box.
{
  python3,
  symlinkJoin,
  wireshark-cli,
  gdb,
  writeShellScriptBin,
  labBox,
  memprocfs,
}:

let
  tool =
    name:
    writeShellScriptBin "guest-${name}" ''
      exec ${python3}/bin/python3 -I -B ${./.} ${name} ${wireshark-cli}/bin ${labBox}/bin/lab-box ${memprocfs}/lib/memprocfs/vmm.so ${../_guest-dbg} ${gdb}/bin/gdb "$@"
    '';
in
symlinkJoin {
  name = "vm-lab-capture-readers";
  paths = [
    (tool "net")
    (tool "usb")
  ];
}

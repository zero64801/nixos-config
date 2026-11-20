# guest-net and guest-usb, which read what a session recorded of its guest, with tshark inside lab-box.
{
  python3,
  symlinkJoin,
  wireshark-cli,
  gdb,
  callPackage,
  writeShellScriptBin,
  labBox,
  memprocfs,
}:

let
  tlsscan = callPackage ./tlsscan/tlsscan.nix { };
  # Brotli for the bodies most servers send, which Python cannot undo by itself, and ls-qpack for HTTP/3's headers, used
  # only inside lab-box.
  python = python3.withPackages (packages: [
    packages.brotli
    packages.pylsqpack
  ]);
  tool =
    name:
    writeShellScriptBin "guest-${name}" ''
      exec ${python}/bin/python3 -I -B ${./.} ${name} ${wireshark-cli}/bin ${labBox}/bin/lab-box ${memprocfs}/lib/memprocfs/vmm.so ${../_guest-dbg} ${gdb}/bin/gdb ${tlsscan}/lib/libtlsscan.so "$@"
    '';
in
symlinkJoin {
  name = "vm-lab-capture-readers";
  paths = [
    (tool "net")
    (tool "usb")
  ];
}

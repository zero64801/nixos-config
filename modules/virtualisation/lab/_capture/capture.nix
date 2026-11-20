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
  protobuf,
}:

let
  tlsscan = callPackage ./tlsscan/tlsscan.nix { };
  # Brotli for the bodies most servers send, which Python cannot undo by itself, ls-qpack for HTTP/3's headers, and
  # cryptography for decoders of a program's own protocol to open what keys own found the keys of, used only inside lab-box.
  python = python3.withPackages (packages: [
    packages.brotli
    packages.cryptography
    packages.pylsqpack
  ]);
  tool =
    name:
    writeShellScriptBin "guest-${name}" ''
      exec ${python}/bin/python3 -I -B ${./.} ${name} ${wireshark-cli}/bin ${labBox}/bin/lab-box ${memprocfs}/lib/memprocfs/vmm.so ${../_guest-dbg} ${gdb}/bin/gdb ${tlsscan}/lib/libtlsscan.so ${protobuf}/bin/protoc "$@"
    '';
in
symlinkJoin {
  name = "vm-lab-capture-readers";
  paths = [
    (tool "net")
    (tool "usb")
  ];
}

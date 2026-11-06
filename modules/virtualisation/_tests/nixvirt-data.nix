# nix build --impure --no-link -L --expr 'import ./modules/virtualisation/_tests/nixvirt-data.nix { }'
{
  pkgs ? import <nixpkgs> { },
}:

let
  # Each part builds its own disks, so the three run side by side.
  part =
    name:
    pkgs.runCommand "nixvirt-data-test-${name}"
      {
        nativeBuildInputs = [
          (pkgs.python3.withPackages (ps: [ ps.guestfs ]))
          pkgs.qemu
          pkgs.coreutils
          pkgs.less
        ];
        # The libguestfs appliance is a VM, and revisions are reflinks, so the build dir must be on btrfs or XFS.
        requiredSystemFeatures = [ "kvm" ];
        LIBGUESTFS_PATH = pkgs.libguestfs-appliance;
        LIBGUESTFS_BACKEND = "direct";
      }
      ''
        tar xzf ${pkgs.hivex.src} --wildcards '*/images/minimal' --strip-components=2
        python3 ${./nixvirt-data-test.py} ${../_nixvirt-data.py} "$PWD/minimal" ${name}
        touch $out
      '';
in
pkgs.runCommand "nixvirt-data-test" {
  parts = map part [
    "windows"
    "resize"
    "linux"
  ];
} "touch $out"

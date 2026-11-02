# nix build --impure --no-link --expr 'import ./modules/virtualisation/_tests/nixvirt-data.nix { }'
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.runCommand "nixvirt-data-test"
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
    python3 ${./nixvirt-data-test.py} ${../_nixvirt-data.py} "$PWD/minimal"
    touch $out
  ''

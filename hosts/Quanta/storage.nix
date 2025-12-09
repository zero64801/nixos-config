{
  lib,
  pkgs,
  ...
}:

let
  storageMountPoint = "/mnt/storage";
  vmStoragePath = "${storageMountPoint}/VMs";
in
{
  boot.initrd.luks.devices."cryptstorage" = {
    device = "/dev/nvme1n1p1";
    crypttabExtraOpts = [ "fido2-device=auto" ];
    allowDiscards = true;
  };

  fileSystems."${storageMountPoint}" = {
    device = "/dev/mapper/cryptstorage";
    fsType = "btrfs";
    options = [
      "noatime"
      "nodiratime"
      "compress=zstd"
      "ssd"
      # Don't fail boot if drive is missing
      "nofail"
    ];
  };

  systemd.tmpfiles.rules = [
    # Create VMs directory owned by qemu-libvirtd
    "d ${vmStoragePath} 0770 qemu-libvirtd qemu-libvirtd -"
  ];

  system.activationScripts.vmStoragePermissions = lib.stringAfter [ "users" "groups" ] ''
    # Wait for mount (nofail means it might not be ready during activation)
    if ${pkgs.util-linux}/bin/mountpoint -q ${storageMountPoint}; then
      # Create VMs directory if it doesn't exist
      ${pkgs.coreutils}/bin/mkdir -p ${vmStoragePath}

      # Set ownership to qemu-libvirtd user/group
      ${pkgs.coreutils}/bin/chown qemu-libvirtd:qemu-libvirtd ${vmStoragePath}

      # Set permissions: owner and group have full access
      ${pkgs.coreutils}/bin/chmod 0770 ${vmStoragePath}

      # Set the No-COW attribute for BTRFS (critical for VM performance)
      # This must be set on the directory, new files will inherit it
      ${pkgs.e2fsprogs}/bin/chattr +C ${vmStoragePath} 2>/dev/null || true

      echo "VM storage permissions configured at ${vmStoragePath}"
    else
      echo "Storage drive not mounted, skipping VM storage setup"
    fi
  '';

  # Systemd service to fix permissions after mount (handles late mounts)
  systemd.services.vm-storage-permissions = {
    description = "Set VM storage directory permissions";
    after = [ "mnt-storage.mount" ];
    requires = [ "mnt-storage.mount" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "setup-vm-storage" ''
        set -euo pipefail

        # Create VMs directory
        mkdir -p ${vmStoragePath}

        # Set ownership
        chown qemu-libvirtd:qemu-libvirtd ${vmStoragePath}
        chmod 0770 ${vmStoragePath}

        # Set No-COW attribute for BTRFS performance
        ${pkgs.e2fsprogs}/bin/chattr +C ${vmStoragePath} 2>/dev/null || true

        # Fix permissions on any existing files
        find ${vmStoragePath} -maxdepth 1 -name "*.qcow2" -exec chown qemu-libvirtd:qemu-libvirtd {} \;

        echo "VM storage ready at ${vmStoragePath}"
      '';
    };
  };

  # Grant read access to browse the storage drive
  # while keeping VMs owned by qemu-libvirtd
  systemd.services.vm-storage-permissions.serviceConfig.ExecStartPost =
    pkgs.writeShellScript "setup-storage-acl" ''
      # Allow user to browse the storage mount
      ${pkgs.acl}/bin/setfacl -m u:dx:rx ${storageMountPoint}
      # Allow user to list VMs directory (but qemu-libvirtd owns the files)
      ${pkgs.acl}/bin/setfacl -m u:dx:rx ${vmStoragePath}
    '';

  # Ensure ACL support is available
  environment.systemPackages = [ pkgs.acl ];
}

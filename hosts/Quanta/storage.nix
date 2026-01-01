{
  pkgs,
  ...
}:

let
  storageMountPoint = "/mnt/storage";
  vmStoragePath = "${storageMountPoint}/VMs";
in
{
  boot.initrd.luks.devices."cryptstorage" = {
    device = "/dev/disk/by-path/pci-0000:07:00.0-nvme-1";
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
      "nofail"
    ];
  };

  # Handle directory creation and permissions
  systemd.tmpfiles.rules = [
    # Make the root storage directory world-writable with sticky bit (1777)
    # This allows any user to create files, but only the owner can delete them.
    "d ${storageMountPoint} 1777 root root - -"

    # VM directory: Keep owned by qemu-libvirtd for Libvirt compatibility
    "d ${vmStoragePath} 0770 qemu-libvirtd qemu-libvirtd - -"

    # Set No-COW attribute for VM folder
    "h ${vmStoragePath} - - - - +C"
  ];

  # Service to enforce permissions and fix ownership
  systemd.services.vm-storage-permissions = {
    description = "Ensure Storage permissions and No-COW";
    after = [ "mnt-storage.mount" ];
    requires = [ "mnt-storage.mount" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "setup-storage" ''
        # 1777 = rwxrwxrwt (Sticky bit protects deletion of others' files)
        chmod 1777 ${storageMountPoint}

        # VM Specific Configuration
        mkdir -p ${vmStoragePath}

        # Set No-COW (Critical for BTRFS performance with VMs)
        ${pkgs.e2fsprogs}/bin/chattr +C ${vmStoragePath} 2>/dev/null || true

        # Enforce Ownership for VM folder so QEMU can access images
        chown qemu-libvirtd:qemu-libvirtd ${vmStoragePath}
        chmod 0770 ${vmStoragePath}

        # Fix any existing VM images inside
        find ${vmStoragePath} -maxdepth 1 -name "*.qcow2" -exec chown qemu-libvirtd:qemu-libvirtd {} \;
      '';
    };
  };
}

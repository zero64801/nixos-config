{
pkgs,
config,
lib,
...
}: {
  options.nyx.virtualisation.enable = lib.mkEnableOption "virtualisation support";
  config = lib.mkIf config.nyx.virtualisation.enable {
    boot.kernelModules = [ "i2c-dev" ];

    users.groups.i2c = { };
    services.udev.extraRules = ''
      KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"
      SUBSYSTEM=="kvmfr", OWNER="qemu-libvirtd", GROUP="kvm", MODE="0660"
    '';

    boot.initrd.kernelModules = [
      "vfio_pci"
      "vfio"
      "vfio_iommu_type1"
      "kvmfr"
    ];

    boot.extraModulePackages = [ config.boot.kernelPackages.kvmfr ];

    boot.extraModprobeConfig = ''
      options vfio-pci ids=10de:2489,10de:228b,1912:0014
      options kvmfr static_size_mb=32
    '';

    networking.firewall.trustedInterfaces = [ "virbr0" ];

    systemd.services.libvirtd.postStart = ''
      VIRSH_CMD="${pkgs.libvirt}/bin/virsh"
      $VIRSH_CMD net-start default || true
    '';

    virtualisation = {
      libvirtd = {
        enable = true;
        qemu = {
          package = pkgs.qemu_kvm;
          runAsRoot = false;
          swtpm.enable = true;
          ovmf = {
            enable = true;
            packages = [(pkgs.OVMFFull.override {
              secureBoot = true;
              tpmSupport = true;
            }).fd];
          };
          verbatimConfig = ''
            namespaces = []
            cgroup_device_acl = [
            "/dev/null", "/dev/full", "/dev/zero",
            "/dev/random", "/dev/urandom",
            "/dev/ptmx", "/dev/kvm", "/dev/kqemu",
            "/dev/rtc", "/dev/hpet", "/dev/vfio/vfio",
            "/dev/kvmfr0",
            ]
          '';
        };
        hooks.qemu = {
          win11 = pkgs.writeShellScript "win11-vfio-hook.sh" ''
            #!${pkgs.bash}/bin/bash
            set -e
            set -x

            HOST_CORES="0-3,8-11"
            ALL_CORES="0-15"

            VM_NAME="$1"
            OPERATION="$2"
            SUB_OPERATION="$3"

            SYSTEMCTL="${pkgs.systemd}/bin/systemctl"

            case "$OPERATION/$SUB_OPERATION" in
            "prepare/begin")
                echo "VFIO-HOOK: Starting for $VM_NAME"
                echo "VFIO-HOOK: Isolating CPUs. Host will use cores: $HOST_CORES"
                $SYSTEMCTL set-property --runtime -- user.slice AllowedCPUs=$HOST_CORES
                $SYSTEMCTL set-property --runtime -- system.slice AllowedCPUs=$HOST_CORES
                $SYSTEMCTL set-property --runtime -- init.scope AllowedCPUs=$HOST_CORES
            ;;

            "release/end")
                echo "VFIO-HOOK: Stopping for $VM_NAME"
                echo "VFIO-HOOK: Restoring all CPU cores ($ALL_CORES) to host"
                $SYSTEMCTL set-property --runtime -- user.slice AllowedCPUs=$ALL_CORES
                $SYSTEMCTL set-property --runtime -- system.slice AllowedCPUs=$ALL_CORES
                $SYSTEMCTL set-property --runtime -- init.scope AllowedCPUs=$ALL_CORES
            ;;
            esac
          '';
        };
      };
      spiceUSBRedirection.enable = true;
    };

    environment.systemPackages = with pkgs; [
      virt-manager
      virt-viewer
      spice-gtk
      #distrobox
    ];

    /*
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
    };
    */
  };
}

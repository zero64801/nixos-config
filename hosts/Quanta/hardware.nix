{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  boot = {
    kernelPackages = pkgs.linuxPackages_zen;
    kernelModules = [
      "kvm-amd"
      "tcp_bbr"
      "ntsync"
    ];
    kernelParams = [
      "amd_pstate=active"
      "transparent_hugepage=madvise"
      "fbcon=map:1"
    ];
    kernel.sysctl = {
      "vm.swappiness" = 30;
      "vm.vfs_cache_pressure" = 50;
      "vm.page-cluster" = 0;
      "vm.dirty_bytes" = 1024 * 1024 * 1024;
      "vm.dirty_background_bytes" = 256 * 1024 * 1024;
      "vm.dirty_writeback_centisecs" = 500;
      "kernel.nmi_watchdog" = 0;
      "kernel.unprivileged_userns_clone" = 1;
      "kernel.kptr_restrict" = 2;
      "net.core.netdev_max_backlog" = 4096;
      "fs.file-max" = 2097152;
      "net.core.default_qdisc" = "fq";
      "net.ipv4.tcp_congestion_control" = "bbr";
    };

    initrd = {
      availableKernelModules = [
        "nvme"
        "ahci"
        "thunderbolt"
        "xhci_pci"
        "usbhid"
        "sd_mod"
      ];

      kernelModules = [ "amdgpu" ];

      # Required for btrfs rollback
      systemd.enable = true;
    };

    extraModulePackages = [ ];
  };

  systemd.services.cpu-dma-latency = {
    description = "PM-QoS: cap CPU wake latency at 100us (bans the 350us C3 idle exit)";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 2;
      ExecStart = pkgs.writeShellScript "cpu-dma-latency" ''
        exec 3<> /dev/cpu_dma_latency
        ${pkgs.coreutils}/bin/printf '\x64\x00\x00\x00' >&3
        exec ${pkgs.coreutils}/bin/sleep infinity
      '';
    };
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
  };

  networking = {
    useDHCP = lib.mkDefault true;
    firewall = {
      allowedTCPPorts = [ ];
      allowedUDPPorts = [ ];
    };
  };

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.keyboard.qmk.enable = true;
  hardware.bluetooth.enable = true;
}

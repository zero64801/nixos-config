{ pkgs, ... }:

{
  # CPU xHCI 6f:00.4 (rear USB-C + one type A)
  boot.kernelParams = [ "vfio-pci.ids=1022:15b7" ];

  nyx.virtualisation = {
    base.enable = true;

    # Xbox 360 pad
    gamepad = {
      enable = true;
      vendorId = "045e";
      productId = "028e";
    };

    desktop = {
      enable = true;

      vfio = {
        enable = true;
        ids = [
          "10de:2b85"
          "10de:22e8"
        ];
        pciAddresses = [
          "01:00.0"
          "01:00.1"
        ];
      };

      looking-glass = {
        enable = true;
        staticSizeMb = 64;
        extraClientConfig.win = {
          autoResize = false;
          allowResize = true;
          noScreensaver = true;
        };
      };

    };

    cpuPinning = {
      enable = true;
      domains = [ "win11" "win11-re" ];
      defaultMode = "classic";
      modes = {
        # CCD1 (8-15 + SMT 24-31): higher clocks, host keeps the X3D CCD.
        classic = {
          vcpuPins = [ 8 24 9 25 10 26 11 27 12 28 13 29 14 30 15 31 ];
          emulatorCpus = "0-1,16-17";
          iothreadCpus = "2,18";
        };
        # CCD0 (0-7 + SMT 16-23): the V-Cache CCD goes to the guest.
        x3d = {
          vcpuPins = [ 0 16 1 17 2 18 3 19 4 20 5 21 6 22 7 23 ];
          emulatorCpus = "8-9,24-25";
          iothreadCpus = "10,26";
        };
      };
    };

    gpuSwitch = {
      enable = true;
      defaultMode = "host";
    };

    sambaShare = {
      enable = true;
      dropPath = "/mnt/storage/VMs/share/drop";
      exchangePath = "/mnt/storage/VMs/share/exchange";
    };

    nixvirt = {
      enable = true;
      domains = [
        {
          definition = ./win11.xml;
          active = null;
          restart = false;
        }
        {
          definition = ./win11-base.xml;
          active = null;
          restart = false;
        }
        {
          definition = ./win11-re.xml;
          active = null;
          restart = false;
        }
      ];
    };
  };

  # lspci, for IOMMU groups and passthrough debugging.
  environment.systemPackages = [ pkgs.pciutils ];
}

{ pkgs, ... }:

{
  boot.kernelParams = [ "vfio-pci.ids=1022:15b7" ];

  my.virtualisation = {
    base.enable = true;

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
        classic = {
          vcpuPins = [ 8 24 9 25 10 26 11 27 12 28 13 29 14 30 15 31 ];
          emulatorCpus = "0-1,16-17";
          iothreadCpus = "2,18";
        };
        x3d = {
          vcpuPins = [ 0 16 1 17 2 18 3 19 4 20 5 21 6 22 7 23 ];
          emulatorCpus = "8-9,24-25";
          iothreadCpus = "10,26";
        };
      };
    };

    gpuMode = {
      enable = true;
      domains = {
        win11 = { };
        win11-re = { };
      };
      modes.virtual.resolution = "2560x1440";
      modes.virtual.accel3d = true;
      renderNode = "/dev/dri/renderD128";
    };

    gpuSwitch = {
      enable = true;
      defaultMode = "host";
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
        {
          definition = ./linux-re.xml;
          active = null;
          restart = false;
        }
      ];

      untrusted = [
        "win11-re"
        "linux-re"
      ];

      dataDisks.win11-re = {
        image = "/mnt/storage/VMs/images/win11-re.data.img";
        serial = "S6PTNS0W418265K";
        vendor = "Samsung";
        product = "SSD 850 PRO 512G";
        sourcePaths = [ "Projects" ];
        highlight = {
          "RUNS CODE" = [
            "claude/settings.json"
            "claude/settings.local.json"
            "claude/managed-settings.json"
            "claude/.claude.json"
            "claude/plugins/*"
            "claude/hooks/*"
            "*/.claude/settings*.json"
            "*/.mcp.json"
          ];
          "STEERS CLAUDE" = [
            "claude/CLAUDE.md"
            "claude/rules/*"
            "claude/skills/*"
            "claude/agents/*"
            "claude/commands/*"
            "claude/output-styles/*"
            "claude/projects/*/memory/*"
            "*/CLAUDE.md"
            "*/CLAUDE.local.md"
            "*/AGENTS.md"
            "*/.claude/*"
          ];
        };
        rescueRoot = "Users/sw";
        rescueExclude = [
          "AppData"
          "NTUSER.DAT*"
          "ntuser.*"
        ];
        windows = {
          letter = "D";
          carry = {
            "Users/sw/Desktop/Tools" = "Tools";
            "Users/sw/Desktop/Projects" = "Projects";
            "Users/sw/.claude" = "claude";
            "Users/sw/.claude.json" = "claude/.claude.json";
            "Users/sw/.vscode" = "vscode";
          };
          userEnv.sw.CLAUDE_CONFIG_DIR = "D:\\claude";
        };
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d /mnt/storage 0755 root root -"
    "d /mnt/storage/VMs 0755 root root -"
    "d /mnt/storage/VMs/images 0755 root root -"
    "d /mnt/storage/VMs/ISO 0755 root root -"
  ];

  environment.systemPackages = [ pkgs.pciutils ];
}

{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) literalExpression mkEnableOption mkIf mkMerge mkOption concatStringsSep;
  inherit (lib.types) attrsOf int listOf path str;

  cfg = config.my.virtualisation.desktop;
  gpuSwitchCfg = config.my.virtualisation.gpuSwitch;

  hugepagesHook = pkgs.writeShellScript "libvirt-hook-hugepages" (
    ''
      # libvirt runs hooks with a PATH that lacks util-linux and its flock.
      export PATH="${lib.makeBinPath [ pkgs.util-linux ]}:$PATH"
    ''
    + builtins.readFile ./_hugepages-hook.sh
  );

  lgClient = "${pkgs.looking-glass-client}/bin/looking-glass-client";

  # The client keeps reconnecting to whichever guest serves SPICE next, so a shared clipboard is only safe while the guests that were running at launch stay the only ones.
  lgLaunch = pkgs.writeShellApplication {
    name = "looking-glass-launch";
    runtimeInputs = [
      config.virtualisation.libvirtd.package
      pkgs.coreutils
      pkgs.libnotify
    ];
    text = ''
      untrusted=" ${concatStringsSep " " config.my.virtualisation.nixvirt.untrusted} "

      lg_domains() {
        virsh -r -c qemu:///system list --state-running --name | while IFS= read -r d; do
          [ -n "$d" ] || continue
          xml=$(virsh -r -c qemu:///system dumpxml "$d") || continue
          case "$xml" in *"/dev/kvmfr"*) printf '%s ' "$d" ;; esac
        done
      }

      clipboard=auto
      if [ "''${1:-}" = --clipboard ]; then
        clipboard=on
        shift
      fi

      allowed=$(lg_domains || true)
      if [ "$clipboard" = auto ]; then
        clipboard=on
        [ -n "$allowed" ] || clipboard=off
        for d in $allowed; do
          case "$untrusted" in *" $d "*) clipboard=off ;; esac
        done
      fi

      if [ "$clipboard" = off ]; then
        exec ${lgClient} "$@" spice:clipboard=no clipboard:toVM=no clipboard:toLocal=no
      fi

      ${lgClient} "$@" &
      client=$!
      trap 'kill "$client" 2>/dev/null || true' TERM INT HUP

      while kill -0 "$client" 2>/dev/null; do
        sleep 1
        now=$(lg_domains) || continue
        if [ -z "$allowed" ]; then
          allowed=$now
          continue
        fi
        for d in $now; do
          case " $allowed " in
            *" $d "*) ;;
            *)
              kill "$client" 2>/dev/null || true
              notify-send -a "Looking Glass" "Looking Glass closed" "$d started while the clipboard was shared." || true
              exit 0
              ;;
          esac
        done
      done
      wait "$client"
    '';
  };
in
{
  options.my.virtualisation.desktop = {
    enable = mkEnableOption "desktop virtualisation features (vfio, looking-glass, libvirt hooks)";

    vfio = {
      enable = mkEnableOption "VFIO/IOMMU GPU passthrough support";

      ids = mkOption {
        type = listOf str;
        default = [ ];
        description = "PCI device IDs to bind to vfio-pci driver";
        example = [
          "10de:1b80"
          "10de:10f0"
        ];
      };

      pciAddresses = mkOption {
        type = listOf str;
        default = [ ];
        description = "PCI bus addresses to detach for passthrough";
        example = [
          "01:00.0"
          "01:00.1"
        ];
      };
    };

    looking-glass = {
      enable = mkEnableOption "Looking Glass (kvmfr) support";

      staticSizeMb = mkOption {
        type = int;
        default = 32;
        description = "Static size in MB for the kvmfr module";
      };

      launcher = mkOption {
        type = lib.types.package;
        readOnly = true;
        default = lgLaunch;
        description = ''
          looking-glass-launch: starts the client with the clipboard off while an untrusted domain uses kvmfr,
          or with --clipboard on regardless. A client sharing the clipboard is closed when another kvmfr domain starts.
        '';
      };

      escapeKey = mkOption {
        type = str;
        default = "KEY_RIGHTCTRL";
        description = "Looking Glass escape key (Linux input event keycode).";
      };

      extraClientConfig = mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.int lib.types.bool ]));
        default = { };
        description = ''
          Extra sections/keys merged into ~/.config/looking-glass/client.ini.
          Example: { spice.enable = false; win.fullScreen = true; }
        '';
      };
    };

    hooks = mkOption {
      type = attrsOf path;
      default = { };
      description = "Libvirt hooks for VM lifecycle management";
      example = literalExpression ''
        {
          win11 = ./win11-hook.sh;
        }
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.vfio.enable {
      boot.initrd.kernelModules = [
        "vfio_pci"
        "vfio"
        "vfio_iommu_type1"
      ];

      boot.kernelParams = [
        "amd_iommu=force_enable"
        "iommu=pt"
        "kvm.ignore_msrs=1"
      ];

      my.virtualisation.base.extraModprobeConfigLines =
        mkIf (cfg.vfio.ids != [ ] && (!gpuSwitchCfg.enable || gpuSwitchCfg.defaultMode == "vfio"))
          [
            "options vfio-pci ids=${concatStringsSep "," cfg.vfio.ids}"
          ];

      my.virtualisation.base.cgroupDeviceACL = [ "/dev/vfio/vfio" ];
    })

    (mkIf cfg.looking-glass.enable {
      boot.kernelModules = [ "kvmfr" ];
      boot.extraModulePackages = [ config.boot.kernelPackages.kvmfr ];

      # Its own group, so only the client and the domains that use it share the frame memory, not everything in kvm.
      services.udev.extraRules = ''
        SUBSYSTEM=="kvmfr", OWNER="root", GROUP="kvmfr", MODE="0660"
      '';
      users.groups.kvmfr = { };
      my.security.serviceAdminGroups = [ "kvmfr" ];

      my.virtualisation.base.extraModprobeConfigLines = [
        "options kvmfr static_size_mb=${toString cfg.looking-glass.staticSizeMb}"
      ];

      my.virtualisation.base.cgroupDeviceACL = [ "/dev/kvmfr0" ];

      environment.systemPackages = [
        pkgs.looking-glass-client
        lgLaunch
      ];

      # Same id as the package's own entry, so the menu, launchers and pins all go through the clipboard policy.
      hm.xdg.desktopEntries.looking-glass-client = {
        name = "Looking Glass Client";
        genericName = "Virtual Machine Viewer";
        comment = "Client for Looking Glass KVMFR";
        exec = lib.getExe lgLaunch;
        icon = "looking-glass";
        terminal = false;
        categories = [ "System" ];
        settings = {
          Keywords = "KVM;VM;VFIO;";
          StartupWMClass = "looking-glass-client";
          SingleMainWindow = "true";
        };
      };

      hm.xdg.configFile."looking-glass/client.ini".text =
        let
          baseConfig = {
            app = {
              shmFile = "/dev/kvmfr0";
            };
            input = {
              escapeKey = cfg.looking-glass.escapeKey;
              rawMouse = true;
              ignoreWindowsKeys = true;
            };
            win = {
              fullScreen = false;
              autoResize = true;
              keepAspect = true;
              quickSplash = true;
            };
            spice = {
              enable = true;
              clipboard = true;
              audio = true;
            };
          };
          merged = lib.recursiveUpdate baseConfig cfg.looking-glass.extraClientConfig;
          renderValue = v:
            if builtins.isBool v then (if v then "yes" else "no")
            else toString v;
          renderSection = name: kvs:
            "[${name}]\n" +
            (lib.concatStringsSep "\n"
              (lib.mapAttrsToList (k: v: "${k}=${renderValue v}") kvs)) +
            "\n";
        in
        lib.concatStringsSep "\n"
          (lib.mapAttrsToList renderSection merged);
    })

    {
      virtualisation.libvirtd.hooks.qemu =
        {
          "10-hugepages" = hugepagesHook;
        }
        // lib.mapAttrs (name: src:
          pkgs.writeShellScript "libvirt-hook-${name}" (builtins.readFile src)
        ) cfg.hooks;
      virtualisation.spiceUSBRedirection.enable = true;
      environment.systemPackages = [ pkgs.spice-gtk ];

      systemd.services.libvirtd-config.restartTriggers =
        [ hugepagesHook ] ++ lib.attrValues cfg.hooks;
    }
  ]);
}

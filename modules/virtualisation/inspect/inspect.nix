{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.my.virtualisation.inspect;
  python = "${pkgs.python3}/bin/python3";
  # The helper talks to libvirt itself, for the agent in the guest.
  helperPython = "${pkgs.python3.withPackages (p: [ p.libvirt ])}/bin/python3";

  # pkexec runs this as root, so it reads nothing from its caller but the domain name and one flag.
  helper = pkgs.writeShellScript "vm-inspect-open" ''
    exec ${helperPython} -I ${./_inspect_helper.py} ${
      pkgs.writeText "vm-inspect-open.json" (
        builtins.toJSON {
          inherit (cfg) domains;
          virsh = "${config.virtualisation.libvirtd.package}/bin/virsh";
          setfacl = "${pkgs.acl}/bin/setfacl";
          # For the kernel's USB monitor, which is loaded when a session first records USB.
          modprobe = "${pkgs.kmod}/bin/modprobe";
        }
      )
    } "$@"
  '';

  vm-inspect = pkgs.writeShellScriptBin "vm-inspect" ''
    exec ${python} -I ${./_inspect.py} ${
      pkgs.writeText "vm-inspect.json" (
        builtins.toJSON {
          inherit (cfg) domains;
          inherit helper;
          pkexec = "${config.security.wrapperDir}/pkexec";
          capture_limit = cfg.capture.limit;
        }
      )
    } "$@"
  '';

  guest = tool: pkgs.writeShellScriptBin "guest-${tool}" ''
    exec ${python} -I -B ${./_guest} ${tool} "$@"
  '';

  # MemProcFS, built to read a guest's memory through a session's socket.
  memprocfs = pkgs.callPackage ./_memprocfs/memprocfs.nix { };

  guestTools = pkgs.symlinkJoin {
    name = "vm-inspect-guest-tools";
    paths = map guest [
      "shot"
      "input"
      "agent"
      "exec"
      "py"
      "job"
      "wait"
      "windows"
      "read"
      "push"
      "pull"
      "ls"
      "stat"
      "hash"
      "grep"
      "find"
      "status"
      "mark"
    ];
  };
in
{
  options.my.virtualisation.inspect = {
    enable = mkEnableOption ''
      vm-inspect, which opens a running guest's memory and QEMU's debug stub to the user who asks, as a DMA card would
      for a physical machine. It takes a guest whose memory QEMU shares, such as one backed by a memfd, as it runs:
      nothing is added to the domain, so a guest that is never opened is not changed by this. Opening one asks for an
      administrator through pkexec, and hands over everything in the guest's memory, to read and to change. A session
      also gives pictures of the guest's screen (guest-shot) and, when opened with --control, takes keys and pointer
      events for the guest (guest-input) and plugs in a channel to the agent that runs in it (guest-agent), which
      it takes out again at its end. Opened with --net or --usb, it records what the guest sends and gets over its
      network devices and the USB devices passed to it, read from this side, into ~/.local/state/vm-inspect/captures
    '';

    domains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "malware-lab" ];
      description = "Libvirt domains that may be opened.";
    };

    capture.limit = mkOption {
      type = types.ints.positive;
      default = 4 * 1024 * 1024 * 1024;
      defaultText = lib.literalExpression "4 * 1024 * 1024 * 1024";
      description = ''
        Bytes a session that records the guest writes at most, network and USB together. It stops recording when it
        gets there, or when less than 512 MiB are left on the disk, and says so. Older captures are kept until
        they are deleted.
      '';
    };

    package = mkOption {
      type = types.package;
      readOnly = true;
      default = vm-inspect;
      description = "The vm-inspect tool, exposed for wrapping it and for testing outside a switch.";
    };

    guestTools = mkOption {
      type = types.package;
      readOnly = true;
      default = guestTools;
      description = ''
        The tools that work in a session: guest-shot, guest-input, guest-agent and those on top of the agent.
        They are on no path by themselves. What they print was made by the guest, so they belong where such
        data may be handled, which is for a sandbox around vm-inspect to provide.
      '';
    };

    guestLibrary = mkOption {
      type = types.path;
      readOnly = true;
      default = ./_guest;
      description = "The Python the guest tools are made of, for a module that builds another tool on a session.";
    };

    memprocfs = mkOption {
      type = types.package;
      readOnly = true;
      default = memprocfs;
      description = ''
        MemProcFS with the device that reads a session's memory socket, and its library, for whatever wraps a
        session. It is on no path by itself, for the reason the guest tools are not.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.security.polkit.enable && config.security.polkit.enablePkexecWrapper;
        message = "my.virtualisation.inspect starts its helper through pkexec, which needs security.polkit.enable and enablePkexecWrapper.";
      }
    ];

    environment.systemPackages = [ vm-inspect ];

    # Where sessions put their sockets. Present from the start, so that a sandbox can be given the folders before any session exists.
    systemd.tmpfiles.rules = [ "d /run/vm-inspect 0755 root root -" ];
    systemd.user.tmpfiles.rules = [ "d %t/vm-inspect 0700 - - -" ];
  };
}

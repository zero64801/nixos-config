{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.my.virtualisation.inspect;
  python = "${pkgs.python3}/bin/python3";

  # pkexec runs this as root, so it reads nothing from its caller but the domain name and one flag.
  helper = pkgs.writeShellScript "vm-inspect-open" ''
    exec ${python} -I ${./_inspect_helper.py} ${
      pkgs.writeText "vm-inspect-open.json" (
        builtins.toJSON {
          inherit (cfg) domains;
          virsh = "${config.virtualisation.libvirtd.package}/bin/virsh";
          setfacl = "${pkgs.acl}/bin/setfacl";
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
        }
      )
    } "$@"
  '';
in
{
  options.my.virtualisation.inspect = {
    enable = mkEnableOption ''
      vm-inspect, which opens a running guest's memory and QEMU's debug stub to the user who asks, as a DMA card would
      for a physical machine. It takes a guest whose memory QEMU shares, such as one backed by a memfd, as it runs:
      nothing is added to the domain, so a guest that is never opened is not changed by this. Opening one asks for an
      administrator through pkexec, and hands over everything in the guest's memory, to read and to change
    '';

    domains = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "malware-lab" ];
      description = "Libvirt domains that may be opened.";
    };

    package = mkOption {
      type = types.package;
      readOnly = true;
      default = vm-inspect;
      description = "The vm-inspect tool, exposed for wrapping it and for testing outside a switch.";
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

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkDefault mkEnableOption mkIf mkOption types;

  cfg = config.my.security.restrictTrafficControl;

  defaultQdisc = config.boot.kernel.sysctl."net.core.default_qdisc" or null;
  # fq_codel is the default systemd sets where the host names none.
  keep = cfg.keep ++ [ "sch_fq_codel" ] ++ lib.optional (defaultQdisc != null) "sch_${defaultQdisc}";

  # Read from the kernel being installed, so the list follows its updates.
  blocked = pkgs.runCommand "restrict-traffic-control.conf" { keep = toString keep; } ''
    shopt -s nullglob
    for module in ${config.system.modulesTree}/lib/modules/*/kernel/net/sched/*.ko*; do
      name=''${module##*/}
      name=''${name%%.ko*}
      case " $keep " in
        *" $name "*) ;;
        *) echo "install $name ${pkgs.coreutils}/bin/false" ;;
      esac
    done > $out
  '';
in
{
  options.my.security.restrictTrafficControl = {
    enable = mkEnableOption ''
      refusing to load the kernel's traffic control modules, apart from those in keep.
      A program that creates a user namespace is the admin of a network of its own, and the kernel loads a queueing
      discipline, classifier or action for it on request. That code has a long record of privilege escalations
    '';

    keep = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "sch_cake" ];
      description = ''
        Traffic control modules that still load, by module name, next to fq_codel and the one behind net.core.default_qdisc.
        A tc command that needs a refused module fails with an error that names it.
      '';
    };
  };

  config = {
    # Any program can switch a terminal to another line discipline, and the kernel loads that discipline's module for it,
    # code written for serial modems that has given root more than once. With 0 only root loads them.
    boot.kernel.sysctl."dev.tty.ldisc_autoload" = mkDefault 0;

    # blacklist only stops loading by alias, install replaces the load itself.
    environment.etc."modprobe.d/restrict-traffic-control.conf" = mkIf cfg.enable { source = blocked; };
  };
}

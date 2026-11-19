{ config, lib, options, pkgs, ... }:

let
  cfg = config.my.virtualisation.lab;

  base = {
    package = pkgs.runCommand "vm-lab-env" { } "mkdir -p $out/bin";
    name = "vm-lab";
    appId = "org.nixos.VmLab";
    home = "ephemeral";
    linger = false;
    workdir = "ro";

    seccomp = {
      nesting = true;
      devel = true;
    };
    devices = [ "/dev/fuse" ];

    binds.rw = [
      "./out"
      {
        from = "xdg-cache/vm-lab/work";
        to = "cache";
      }
    ];
    # Captures are written by the session alone, and tools add to one through its control socket.
    binds.ro = [
      "xdg-run/vm-inspect"
      "xdg-run/vm-lab"
      "/run/vm-inspect"
      "xdg-state/vm-inspect/captures"
    ];
    env.__NIXOS_SET_ENVIRONMENT_DONE = "1";
    envPassthrough = [
      "COLORTERM"
      "VM_INSPECT_DOMAIN"
      "VM_INSPECT_DIR"
      "VM_INSPECT_DEVICE"
      "VM_INSPECT_GDB"
      "VM_INSPECT_CAPTURE"
      "VM_LAB_TOOLS"
      "VM_LAB_PATH"
      "VM_LAB_ENV"
      "VM_LAB_ONLINE"
      "PDBCRUST_SYMBOL_SOCKET"
    ];
  };

  launcher =
    v:
    let
      w = config.confine.lib.wrap (
        base
        // lib.optionalAttrs v.online { network = "isolated"; }
        // lib.optionalAttrs v.x11 { x11 = "host"; }
        // lib.optionalAttrs (!v.full) { resources = cfg.limits; }
        // lib.optionalAttrs (v.kept != { }) {
          binds = base.binds // {
            rw = base.binds.rw ++ lib.mapAttrsToList (state: place: {
              from = "xdg-state/${state}";
              to = place;
            }) v.kept;
          };
        }
      );
    in
    "${w.launcher}/bin/${w.launcher.name}";
in
{
  # A system without the confine module keeps the lab, with no sandbox around it, and can drop this file.
  config = lib.mkIf (options ? confine) {
    my.virtualisation.lab.sandbox = lib.mkDefault launcher;
  };
}

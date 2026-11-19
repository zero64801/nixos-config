{ lib, pkgs, ... }:

{
  options.my.apps.hostGate.package = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = pkgs.writeShellScriptBin "host-gate" ''
      exec ${pkgs.python3}/bin/python3 -I -B ${./_host_gate.py} "$@"
    '';
    description = ''
      host-gate, for a sandbox that has no network and still needs to reach a few named hosts. Its gate runs outside
      and listens on a unix socket as an HTTP proxy that takes CONNECT for the hosts it was given alone. Its door
      runs inside and gives programs a proxy address that leads to that socket.
    '';
  };
}

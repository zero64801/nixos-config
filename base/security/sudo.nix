{ ... }:

{
  security.sudo = {
    execWheelOnly = true;

    extraRules = [
      {
        groups = [ "wheel" ];
        commands = [
          {
            command = "/run/current-system/sw/bin/nixos-rebuild";
            options = [ "SETENV" "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}

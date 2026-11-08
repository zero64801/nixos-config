{ config, lib, ... }:

let
  pathFor =
    extra:
    lib.concatStringsSep ":" (
      [ "/run/wrappers/bin" ] ++ extra ++ [ "/nix/var/nix/profiles/default/bin" "/run/current-system/sw/bin" ]
    );

  normalUsers = lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);
in
{
  security.sudo = {
    execWheelOnly = true;

    # Later lines win in sudoers, so the per user Defaults follow the general one and NOSETENV follows NixOS's SETENV rule for wheel.
    extraConfig = lib.concatLines (
      [
        "Defaults timestamp_timeout=0"
        ''Defaults secure_path="${pathFor [ ]}"''
      ]
      ++ map (u: ''Defaults:${u} secure_path="${pathFor [ "/etc/profiles/per-user/${u}/bin" ]}"'') normalUsers
      ++ [ "%wheel ALL=(ALL:ALL) NOSETENV: ALL" ]
    );
  };
}

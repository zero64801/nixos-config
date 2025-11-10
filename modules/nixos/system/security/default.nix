{ lib, ... }:

{
  imports = [
    ./yubikey.nix
  ];

  options.nyx.security.serviceAdminGroups = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      A list of groups that grant administrative access to system services.
      Service modules can add their group to this list.
    '';
  };
}

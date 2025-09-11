{ lib, ... }:
{
  options = {
    nyx.data.users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "list of users (duh)";
    };
  };
  
  config = {
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
  };
}

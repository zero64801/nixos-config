{ lib, config, inputs, pkgs, ... }:

{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    (lib.mkAliasOptionModule [ "hm" ] [ "home-manager" "users" config.my.flake.user ])
  ];

  # A plain bool, not a users.users check: home-manager's useUserPackages contributes users.users names, so gating on them infinitely recurses.
  options.my.homeManager.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Instantiate home-manager for my.flake.user. Disable on hosts without that user.";
  };

  config = lib.mkIf config.my.homeManager.enable {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupCommand = "${pkgs.coreutils}/bin/mv --backup=numbered";
      sharedModules = [
        inputs.plasma-manager.homeModules.plasma-manager
      ];

      extraSpecialArgs = {
        inherit inputs;
        stateVersion = config.system.stateVersion;
      };
    };

    hm.home.stateVersion = lib.mkDefault config.system.stateVersion;
    hm.gtk.gtk4.theme = lib.mkIf config.my.desktop.enable (lib.mkDefault null);
  };
}

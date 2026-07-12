{ lib, config, inputs, pkgs, ... }:

{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    (lib.mkAliasOptionModule [ "hm" ] [ "home-manager" "users" config.nyx.flake.user ])
  ];

  # A plain bool, not a users.users check: home-manager's useUserPackages
  # contributes users.users names, so gating on them infinitely recurses.
  options.nyx.homeManager.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Instantiate home-manager for nyx.flake.user. Disable on hosts without that user.";
  };

  config = lib.mkIf config.nyx.homeManager.enable {
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
    hm.gtk.gtk4.theme = lib.mkIf config.nyx.desktop.enable (lib.mkDefault null);
  };
}

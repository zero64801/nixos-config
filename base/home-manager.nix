{ lib, config, inputs, pkgs, ... }:

{
  imports = [
    inputs.home-manager.nixosModules.home-manager
    inputs.impermanence.nixosModules.impermanence
    inputs.disko.nixosModules.disko

    # Let us use `hm` as shorthand for home-manager user config
    (lib.mkAliasOptionModule [ "hm" ] [ "home-manager" "users" config.nyx.flake.user ])
  ];

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
}

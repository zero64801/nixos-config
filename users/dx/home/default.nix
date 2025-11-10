{ config, lib, pkgs, stateVersion, ... }:

{
  imports = [
    ./programs
  ];

  home = {
    stateVersion = lib.mkDefault stateVersion;

    # User-specific packages
    packages = with pkgs; [
      vim
      wget
      curl
      fastfetch
    ];
  };
}

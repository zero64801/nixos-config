{lib, ...}: let
  inherit (lib) mkEnableOption;
in {
  imports = [
    ./nix
    ./system
    ./graphics
    ./programs
    ./server
    ./utils
    ./external
  ];

  options = {
    # basically used across the tree to disable certain modules that are enabled by default
    # which are unecesary for the tree
    nyx.data.headless = mkEnableOption "headless";
  };
}

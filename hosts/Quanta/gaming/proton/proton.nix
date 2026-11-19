{ pkgs, ... }:

let
  mkProtonBin = pkgs.callPackage ./_mk-proton-bin.nix { };
in
{
  my.apps.gaming.steam.compatPackages = [
    (pkgs.callPackage ./_proton-cachyos-v3-bin.nix { inherit mkProtonBin; })
  ];
}

{
  pkgs,
  lib,
  npins,
}:
lib.fix (self: let
  inherit (lib) callPackageWith;
  callPackage = callPackageWith (pkgs // self);
in {
  npins-show = callPackage ./npins-show.nix {inherit npins;};
})

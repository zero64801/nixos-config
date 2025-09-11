# sudo nixos-rebuild --no-reexec --file . -A nixosConfigurations.<hostName> <switch|boot|test|...>
# why? I wasted 3 weeks figuring this out, you are welcome :>
# see the Makefile for more commands
{
  sources ? {},
  sources' ? (import ./npins) // sources,
  nixpkgs ? sources'.nixpkgs,
  allowUnfree ? true,
  pkgs ? import nixpkgs {config = {inherit allowUnfree;};},
  useNpinsV6 ? true,
}:
pkgs.lib.fix (self: let
  inherit (pkgs.lib) mapAttrs callPackageWith warn;
  callPackage = callPackageWith (pkgs // self.packages);

  # WARNING
  # set useNpinsV6 to false if your sources are not v6
  # https://github.com/andir/npins?tab=readme-ov-file#using-the-nixpkgs-fetchers
  sources =
    if useNpinsV6
    then mapAttrs (k: v: v {inherit pkgs;}) sources'
    else sources';
in {
  overlays = {

  };

  packages = {
    inherit sources;

    # trivial
    npins = callPackage ./pkgs/npins.nix {};
    stash = callPackage (sources.stash + "/nix/package.nix") {};

    # package sets
    scripts = callPackage ./pkgs/scripts {};

    # lib
    craneLib = callPackage (sources.crane + "/lib") {};

    # temp
    mbake = pkgs.mbake.overrideAttrs (_prev: {src = sources.bake;});
    # JUST SO YOU KNOW `nivxvim` WAS JUST WHAT I USED TO CALL MY nvim alright
    # I had ditched the nixvim project long long long ago but the name just stuck
    nixvim-minimal = warn "please use xvim.minimal instead" self.packages.xvim.minimal;
    nixvim = warn "please use xvim.default instead" self.packages.xvim.default;
  };

  nixosModules = {
  };

  devShells.default = callPackage ./devShells {};
  nixosConfigurations = callPackage ./hosts {};
})

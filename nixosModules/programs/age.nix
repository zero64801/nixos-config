{
  lib,
  sources,
  pkgs,
  ...
}: {
  imports = [
    (sources.agenix + "/modules/age.nix")
    (lib.mkAliasOptionModule ["nyx" "secrets"] ["age" "secrets"])
  ];
  environment.systemPackages = [(pkgs.callPackage "${sources.agenix}/pkgs/agenix.nix" {})];
}

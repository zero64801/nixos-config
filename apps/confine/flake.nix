{
  description = "Bubblewrap sandboxes for NixOS packages";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # These tests return a summary string or throw.
      evaluated = name: pkgs.writeText "confine-${name}" (import ./_tests/${name}.nix { inherit pkgs; });
    in
    {
      nixosModules.default = ./default.nix;

      checks.${system} = {
        eval = evaluated "eval";
        module = evaluated "module";
        launcher = import ./_tests/launcher.nix { inherit pkgs; };
        seccomp = import ./_tests/seccomp.nix { inherit pkgs; };
        seccomp-drift = import ./_tests/seccomp-drift.nix { inherit pkgs; };
      };
    };
}

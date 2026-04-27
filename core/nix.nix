{ inputs, ... }:

{
  nixpkgs = {
    config.allowUnfree = true;
    overlays = [ (import ../pkgs/default.nix inputs) ];
  };

  nix = {
    #package = pkgs.lix;
    channel.enable = false;

    settings = {
      experimental-features = [ "nix-command" "flakes" "pipe-operator" ];
      # nixpkgs lib still uses `or` as an identifier in places.
      # Lix warns unless we acknowledge it via deprecated-features.
      extra-deprecated-features = [ "or-as-identifier" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "@wheel" ];

      substituters = [ "https://nix-community.cachix.org" ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };

    gc = {
      persistent = true;
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };
}

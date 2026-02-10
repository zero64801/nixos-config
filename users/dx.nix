{ pkgs, config, ... }:

{
  users.users.dx = {
    description = "dx";
    shell = pkgs.fish;
    isNormalUser = true;

    extraGroups = [
      "wheel"
      "networkmanager"
      "tss"
      "gamemode"
    ] ++ config.nyx.security.serviceAdminGroups;

    hashedPasswordFile = "/persist/local/secrets/passwd/dx";

    packages = with pkgs; [
      git
    ];
  };

  # User-specific home-manager packages
  # Note: 'hm' alias targets the primary user (dx) configured in nyx.flake.user
  hm.home.packages = with pkgs; [
    vim
    wget
    curl
    fastfetch
  ];
}

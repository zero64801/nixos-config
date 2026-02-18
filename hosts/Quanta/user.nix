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

  hm.home.packages = with pkgs; [
    vim
    wget
    curl
    fastfetch
  ];
}

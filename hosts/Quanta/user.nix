{ pkgs, config, lib, ... }:

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

    hashedPasswordFile =
      if config.nyx.sops.enable or false
      then config.sops.secrets."users/dx".path
      else "/persist/local/secrets/passwd/dx";

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

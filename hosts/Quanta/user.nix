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
      "video"
    ] ++ config.my.security.serviceAdminGroups;

    hashedPasswordFile = "/persist/local/secrets/passwd/dx";
  };

  hm.home.packages = with pkgs; [
    vim
    wget
    curl
    fastfetch
  ];
}

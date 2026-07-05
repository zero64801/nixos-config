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
      # nvscope: DRM master on the passthrough card's own connector needs rw on its /dev/dri node.
      "video"
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

{ pkgs, config, ... }:

{
  users.users.dx = {
    description = "dx";
    shell = pkgs.fish;
    isNormalUser = true;

    # video is for nvscope: DRM master on the passthrough card's own connector needs rw on its /dev/dri node.
    extraGroups = [
      "wheel"
      "networkmanager"
      "tss"
      "gamemode"
      "video"
    ] ++ config.nyx.security.serviceAdminGroups;

    hashedPasswordFile = "/persist/local/secrets/passwd/dx";
  };

  hm.home.packages = with pkgs; [
    vim
    wget
    curl
    fastfetch
  ];
}

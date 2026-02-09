{ pkgs, lib, ... }:

{
  imports = [
    ./desktop
    ./direnv.nix
    ./fish.nix
    ./flatpak.nix
    ./games.nix
  ];

  environment = {
    systemPackages = with pkgs; [
      lsof
      git
    ];

    variables = {
      EDITOR = lib.mkForce "vim";
      MANPAGER = lib.mkForce "vim +Man!";
    };

    sessionVariables = {
      NIXOS_OZONE_WL = "1";
    };
  };

  # Remove nano
  programs.nano.enable = false;

  # Sudo configuration
  security.sudo = {
    execWheelOnly = true;

    extraRules = [
      {
        users = [ "dx" ];
        commands = [
          {
            command = "/run/current-system/sw/bin/nixos-rebuild";
            options = [
              "SETENV"
              "NOPASSWD"
            ];
          }
        ];
      }
    ];
  };
}

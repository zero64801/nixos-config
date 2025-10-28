{pkgs, ...}: {
  imports = [
    # unimported
    ./desktop
    ./gdm.nix

    # internal
    ./age.nix
    ./direnv.nix
    ./keyd.nix
    ./zed.nix
    ./helix.nix
    ./firefox.nix

    # external
    #./lanzaboote.nix

    # this is not an option
    # auto enables fish and overwrites bash
    ./fish.nix

    ./flatpak.nix
  ];

  # global
  environment.systemPackages = [pkgs.git pkgs.npins];

  # requried by gdm leaving it here since all my systems do use nushell
  environment.shells = ["/run/current-system/sw/bin/nu"];

  environment.variables.EDITOR = "vim";
  environment.variables.MANPAGER = "vim +Man!";
  # remove nano
  programs.nano.enable = false;

  # wayland on electron and chromium based apps
  # disable if slow startup time for the same
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  security.sudo = {
    execWheelOnly = true;
    extraRules = [
      {
        users = [ "dx" ];
        # lets me rebuild without having to enter the password
        commands = [
          {
            command = "/run/current-system/sw/bin/nixos-rebuild";
            options = ["SETENV" "NOPASSWD"];
          }
        ];
      }
    ];
  };
}

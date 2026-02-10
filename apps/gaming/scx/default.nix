{
  config,
  pkgs,
  lib,
  ...
}:

let
  scripts = import ./_scripts.nix { inherit pkgs lib; };
  inherit (scripts) scx-env scx-switch scx-gui scx-desktop-item;
in
{
  options.nyx.programs.scx.package = lib.mkOption {
    type = lib.types.package;
    default = scx-switch;
    description = "The scx-switch package to be used by other modules";
  };

  config = {
    environment.systemPackages = [
      scx-env
      scx-switch
      scx-gui
      scx-desktop-item
      pkgs.qt6.qtwayland
      pkgs.adwaita-qt6
      pkgs.nixos-icons
    ];

    services.scx.enable = false;

    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.policykit.exec" &&
            action.lookup("command_line") &&
            action.lookup("command_line").indexOf("${scx-switch}/bin/scx-switch") === 0 &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}

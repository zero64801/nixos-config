{ config, lib, pkgs, ... }:

let
  askAdmin = config.my.security.polkitAskAdmin;
in
{
  options.my.security.polkitAskAdmin = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "org.freedesktop.udisks2.loop-setup"
      "org.freedesktop.Flatpak.app-install"
      "org.freedesktop.Flatpak.runtime-install"
      "org.freedesktop.Flatpak.app-uninstall"
      "org.freedesktop.Flatpak.runtime-uninstall"
      "org.freedesktop.Flatpak.app-update"
      "org.freedesktop.Flatpak.runtime-update"
      "org.freedesktop.Flatpak.update-remote"
      "org.freedesktop.Flatpak.modify-repo"
      "org.freedesktop.fwupd.update-internal"
      "org.freedesktop.fwupd.update-internal-trusted"
      "org.freedesktop.fwupd.update-hotplug-trusted"
      "org.freedesktop.fwupd.modify-device"
    ];
    description = ''
      Actions that ask for an administrator although their package lets the active local session do them outright, by
      its policy or by a rule for wheel: mounting a disk image, which hands a file of the caller's making to the
      kernel's filesystem code, and changing what is installed system wide or in firmware.
    '';
  };

  config = lib.mkIf config.security.polkit.enable {
    # Only where the session would have been let through, so nothing a remote or inactive session is refused gets opened.
    # This file sorts before the rule files packages install, so it answers first.
    security.polkit.extraConfig = lib.mkIf (askAdmin != [ ]) ''
      polkit.addRule(function(action, subject) {
        if (subject.active && subject.local && ${builtins.toJSON askAdmin}.indexOf(action.id) >= 0) {
          return polkit.Result.AUTH_ADMIN;
        }
      });
    '';

    # Sorted after every other rule file, so a rule that grants an action outright still decides first.
    environment.etc."polkit-1/rules.d/zz-no-kept-approvals.rules".source =
      pkgs.runCommand "zz-no-kept-approvals.rules" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        python3 -I ${./_polkit_kept.py} ${config.system.path}/share/polkit-1/actions > $out
      '';
  };
}

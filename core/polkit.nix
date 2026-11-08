{ config, lib, pkgs, ... }:

{
  config = lib.mkIf config.security.polkit.enable {
    # Sorted after every other rule file, so a rule that grants an action outright still decides first.
    environment.etc."polkit-1/rules.d/zz-no-kept-approvals.rules".source =
      pkgs.runCommand "zz-no-kept-approvals.rules" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        python3 -I ${./_polkit_kept.py} ${config.system.path}/share/polkit-1/actions > $out
      '';
  };
}

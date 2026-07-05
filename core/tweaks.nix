{ pkgs, lib, ...}:
{
  system.activationScripts.diff = {
    supportsDryActivation = true;
    text = ''
      if [[ -e /run/current-system ]]; then
        ${lib.getExe pkgs.nushell} -c "
          let diff_closure = ${lib.getExe pkgs.nix} store diff-closures /run/current-system '$systemConfig';
          if \$diff_closure != \"\" {
            let parsed = \$diff_closure
              | lines
              | where \$it =~ KiB
              | where \$it =~ →
              | parse -r '^(?<Package>\S+): (?<Old_Version>[^,]+)(?:.*) → (?<New_Version>[^,]+)(?:.*, )(?<DiffBin>.*)$'
              | update Old_Version { if \$in == '∅' { 'new' } else { \$in } }
              | update New_Version { if \$in == '∅' { 'removed' } else { \$in } }
              | insert Diff {
                get DiffBin
                | ansi strip
                | str trim -l -c '+'
                | into filesize
              }
              | reject DiffBin
              | sort-by -r Diff;
            if (\$parsed | is-not-empty) {
              \$parsed | print
              \$parsed | get Diff | math sum
            }
          }
        "
      fi
    '';
  };

  system.activationScripts.purge-stale-channels = {
    text = ''
      ${pkgs.coreutils}/bin/rm -rf \
        /root/.nix-defexpr/channels \
        /nix/var/nix/profiles/per-user/root/channels
    '';
  };

  system.activationScripts.create-bash-symlink = {
    deps = [ "binsh" "usrbinenv" ];
    text = ''
      ${pkgs.coreutils}/bin/ln -sf /run/current-system/sw/bin/bash /bin/bash
      ${pkgs.coreutils}/bin/ln -sf /run/current-system/sw/bin/bash /usr/bin/bash
    '';
  };
}

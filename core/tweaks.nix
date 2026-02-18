{ pkgs, lib, ...}:
{
  system.activationScripts.diff = {
    supportsDryActivation = true;
    text = ''
      if [[ -e /run/current-system ]]; then
        ${lib.getExe pkgs.nushell} -c "
          let diff_closure = ${lib.getExe pkgs.nix} store diff-closures /run/current-system '$systemConfig';
          if \$diff_closure != \"\" {
            \$diff_closure
            | lines
            | where \$it =~ KiB
            | where \$it =~ →
            | parse -r '^(?<Package>\S+): (?<Old_Version>[^,]+)(?:.*) → (?<New_Version>[^,]+)(?:.*, )(?<DiffBin>.*)$'
            | insert Diff {
              get DiffBin
              | ansi strip
              | str trim -l -c '+'
              | into filesize
            }
            | reject DiffBin
            | sort-by -r Diff
            | tee { print }
            | if (\$in | is-not-empty) { math sum } else { null }
          }
        "
      fi
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

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

  # Channels are disabled in nix.nix but stale dirs trigger warnings on each
  # rebuild. Remove them once on activation if present.
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

{ pkgs, lib, ...}:
{
  system.activationScripts.diff = {
    supportsDryActivation = true;
    text = let
      # diff-closures always prints sizes in KiB, so filtering on it keeps
      # only lines with a size delta
      diffScript = pkgs.writeText "closure-diff.nu" ''
        def main [new: string] {
          let parsed = ^${lib.getExe pkgs.nix} store diff-closures /run/current-system $new
            | ansi strip
            | lines
            | where $it =~ '→' and $it =~ 'KiB'
            | parse -r '^(?<Package>\S+): (?<Old>.*?) → (?<New>.*?), (?<DiffBin>[+-][0-9.]+ KiB)$'
            | insert Change {|row|
                if $row.Old == '∅' { 'added' } else if $row.New == '∅' { 'removed' } else { 'updated' }
              }
            | update Old { if $in in ['∅', 'ε'] { '-' } else { $in } }
            | update New { if $in in ['∅', 'ε'] { '-' } else { $in } }
            | insert Diff { get DiffBin | str trim -l -c '+' | into filesize }
            | reject DiffBin
            | select Package Change Old New Diff
            | sort-by -r Diff

          if ($parsed | is-not-empty) {
            $parsed | print
            print $"Total: ($parsed | get Diff | math sum)"
          }
        }
      '';
    in ''
      if [[ -e /run/current-system ]]; then
        ${lib.getExe pkgs.nushell} ${diffScript} "$systemConfig"
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
      ${pkgs.coreutils}/bin/ln -sfn /run/current-system/sw/bin/bash /bin/.bash.tmp
      ${pkgs.coreutils}/bin/mv -f /bin/.bash.tmp /bin/bash
      ${pkgs.coreutils}/bin/ln -sfn /run/current-system/sw/bin/bash /usr/bin/.bash.tmp
      ${pkgs.coreutils}/bin/mv -f /usr/bin/.bash.tmp /usr/bin/bash
    '';
  };
}

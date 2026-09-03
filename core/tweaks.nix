{ pkgs, ... }:
{
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

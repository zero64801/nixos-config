{lib, ...}: {
  imports = [
    ./tailscale.nix
    ./openssh.nix
    ./jellyfin.nix
    ./fail2ban.nix
    ./caddy.nix
    ./forgejo.nix
    ./nextcloud.nix
    ./redlib.nix
  ];

  options.nyx.services.enable = lib.mkEnableOption "services";
}

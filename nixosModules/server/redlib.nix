{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.services.redlib;

  inherit (lib) mkIf mkEnableOption;
  inherit (builtins) toString;
in
{
  options.nyx.services.redlib.enable = mkEnableOption "redlib service";

  config = mkIf (config.nyx.services.redlib.enable && config.nyx.services.enable) {
    services.redlib = {
      enable = true;
      openFirewall = true;
    };

    services.caddy.virtualHosts = {
      "redlib.home.arpa" = {
        extraConfig = ''
          reverse_proxy localhost:${toString cfg.port}
        '';
      };
    };

    nyx.impermanence = mkIf config.nyx.impermanence.enable {
      roots.${config.nyx.impermanence.mainPersistRoot} = {
        directories = [
          { directory = "/var/lib/redlib"; user = "redlib"; group = "redlib"; mode = "0750"; }
        ];

        neededFor = [
          "redlib.service"
        ];
      };
    };
  };
}

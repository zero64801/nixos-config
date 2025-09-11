{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.nyx.services.nextcloud;
  
  inherit (lib) mkIf mkEnableOption;
  inherit (builtins) toString;
in {
  options.nyx.services.nextcloud.enable = mkEnableOption "nextcloud service";

  config = mkIf (config.nyx.services.nextcloud.enable && config.nyx.services.enable) {
    age.secrets.nextcloud-admin-pass = {
      file = ../../secrets/secret1.age;
      owner = "nextcloud";
      group = "nextcloud";
    };
     
    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud31;
      hostName = "cloud.home.arpa";
      https = true;
      database.createLocally = true;
      configureRedis = true;
      config = {
        dbtype = "mysql";
        adminuser = "haxxor";
        adminpassFile = config.age.secrets.nextcloud-admin-pass.path;
      };
      settings = {
        default_phone_region = "US";
        mysql.utf8mb4 = true;
        trusted_proxies = [ "127.0.0.1" ];
        overwriteprotocol = "https";
      };
      maxUploadSize = "2G";
    };

    services.caddy.virtualHosts."cloud.home.arpa" = {
      extraConfig = ''
        reverse_proxy localhost:8082
      '';
    };

    services.nginx.virtualHosts."cloud.home.arpa" = {
      listen = [
        { addr = "127.0.0.1"; port = 8082; }
      ];
    };

    services.mysql = {
      enable = true;
      package = pkgs.mariadb;
      ensureDatabases = [ "nextcloud" ];
      ensureUsers = [{
        name = "nextcloud";
        ensurePermissions = {
          "nextcloud.*" = "ALL PRIVILEGES";
        };
      }];
    };
    
    nyx.impermanence = mkIf config.nyx.impermanence.enable {
      roots.${config.nyx.impermanence.mainPersistRoot} = {
        directories = [
          {
            directory = "/var/lib/nextcloud";
            user = "nextcloud";
            group = "nextcloud";
            mode = "0750";
          }
        ];

        neededFor = [
          "nextcloud-setup.service"
          "phpfpm-nextcloud.service"
        ];
      };
    };
  };
}

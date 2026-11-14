{ config, lib, pkgs, ... }:

let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.my.apps.studioBroker;
  inHome = map (folder: "\"%h/${folder}\"");
in
{
  options.my.apps.studioBroker = {
    enable = mkEnableOption ''
      a service of the user's session that launches, lists and stops Roblox Studio in Vinegar's Flatpak, and records
      its sound, for a Lumen server whose sandbox can neither start nor see Studio. It listens on a socket in the
      runtime directory and starts on the first connection. Whatever is given that socket can open and close Studio
    '';

    places = mkOption {
      type = types.str;
      default = ".var/app/org.vinegarhq.Vinegar/data/lumen-places";
      description = "Folder below the home, inside what Vinegar's Flatpak reaches, where sandboxes put the places Studio may open.";
    };

    lockFolders = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ ".var/app/org.vinegarhq.Vinegar/data/vinegar/prefixes/studio/drive_c/users/alice/Downloads" ];
      description = ''
        More folders below the home whose places Studio may open. The lock a killed Studio leaves beside its place is
        deleted there, so no sandbox may be able to write them.
      '';
    };

    idleTimeout = mkOption {
      type = types.ints.positive;
      default = 300;
      description = "Seconds without a connection after which the service stops.";
    };

    socket = mkOption {
      type = types.str;
      readOnly = true;
      default = "studio-broker/socket";
      description = "The socket, below the runtime directory. A sandbox gets its folder read only.";
    };
  };

  config = mkIf cfg.enable {
    # Present from the start, so that a sandbox can be given the folder before anything is put there.
    systemd.user.tmpfiles.rules = [ "d %h/${cfg.places} 0755 - - -" ];

    systemd.user.sockets.studio-broker = {
      description = "Socket of the Roblox Studio launch broker";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "%t/${cfg.socket}" ];
      socketConfig = {
        SocketMode = "0600";
        DirectoryMode = "0700";
      };
    };

    systemd.user.services.studio-broker = {
      description = "Roblox Studio launch broker";
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " (
          [
            (lib.getExe pkgs.nodejs-slim)
            "${./_studio-broker/broker.mjs}"
            (toString cfg.idleTimeout)
            "%S/studio-broker"
          ]
          ++ inHome ([ cfg.places ] ++ cfg.lockFolders)
        );
        StateDirectory = "studio-broker";
        StateDirectoryMode = "0700";
      };
    };
  };
}

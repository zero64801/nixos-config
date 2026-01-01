{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.nyx.programs.steam;
  imp = config.nyx.impermanence;
  gamerUser = "gamer";

  # Auto-detect main admin user
  mainUser = let
    admins = lib.filterAttrs (_: u: u.isNormalUser && lib.elem "wheel" u.extraGroups) config.users.users;
  in lib.head (lib.attrNames admins);

  steamDirs = [
    ".local/share/Steam"
    ".config/Steam"
    ".steam"
  ];

  steam-gamer = pkgs.writeShellScriptBin "steam-gamer" ''
    set -e
    MAIN_UID=$(id -u ${mainUser})
    GAMER_UID=$(id -u ${gamerUser})

    # Check kernel memory map limit
    CURRENT_MAP=$(cat /proc/sys/vm/max_map_count)
    REQUIRED_MAP=2147483642
    if [ "$CURRENT_MAP" -lt "$REQUIRED_MAP" ]; then
      echo "WARNING: vm.max_map_count is too low. Please REBOOT."
      sleep 2
    fi

    cd /tmp

    # --- 1. SETUP RUNTIME DIRECTORY ---
    GAMER_RUNTIME="/tmp/gamer-runtime-$GAMER_UID"
    if [ ! -d "$GAMER_RUNTIME" ]; then
      sudo -u ${gamerUser} mkdir -p -m 0700 "$GAMER_RUNTIME"
    fi

    # --- 2. BRIDGE PERMISSIONS ---

    # Allow traversal of main user's run dir
    ${pkgs.acl}/bin/setfacl -m u:${gamerUser}:x "/run/user/$MAIN_UID"

    # Bridge Wayland
    if [ -n "$WAYLAND_DISPLAY" ]; then
      ${pkgs.acl}/bin/setfacl -m u:${gamerUser}:rw "/run/user/$MAIN_UID/$WAYLAND_DISPLAY"
      sudo -u ${gamerUser} ln -sf "/run/user/$MAIN_UID/$WAYLAND_DISPLAY" "$GAMER_RUNTIME/$WAYLAND_DISPLAY"
    fi

    # Bridge PipeWire (Low level)
    if [ -e "/run/user/$MAIN_UID/pipewire-0" ]; then
      ${pkgs.acl}/bin/setfacl -m u:${gamerUser}:rw "/run/user/$MAIN_UID/pipewire-0"
      sudo -u ${gamerUser} ln -sf "/run/user/$MAIN_UID/pipewire-0" "$GAMER_RUNTIME/pipewire-0"
    fi

    # Bridge PulseAudio (Critical for Game Audio)
    PULSE_SOCKET="/run/user/$MAIN_UID/pulse/native"
    if [ -e "$PULSE_SOCKET" ]; then
      # Allow traversal of the pulse directory
      ${pkgs.acl}/bin/setfacl -m u:${gamerUser}:x "/run/user/$MAIN_UID/pulse"
      # Allow RW on the socket
      ${pkgs.acl}/bin/setfacl -m u:${gamerUser}:rw "$PULSE_SOCKET"

      # Copy the Auth Cookie securely across users
      # 'cat' reads as dx (who owns it), 'tee' writes as gamer (who owns dest)
      if [ -f "$HOME/.config/pulse/cookie" ]; then
        cat "$HOME/.config/pulse/cookie" | sudo -u ${gamerUser} tee "$GAMER_RUNTIME/pulse-cookie" > /dev/null
      fi
    fi

    # Bridge X11
    ${pkgs.xorg.xhost}/bin/xhost +SI:localuser:${gamerUser}

    echo "Launching Steam as ${gamerUser}..."

    # Run Steam
    sudo -u ${gamerUser} /bin/sh -c "
      ulimit -n 524288

      export HOME='/home/${gamerUser}'
      export USER='${gamerUser}'
      export PATH='$PATH'
      export DISPLAY='$DISPLAY'
      export WAYLAND_DISPLAY='$WAYLAND_DISPLAY'
      export XDG_RUNTIME_DIR='$GAMER_RUNTIME'
      export PIPEWIRE_REMOTE='unix:/run/user/$MAIN_UID/pipewire-0'

      # PulseAudio Config
      export PULSE_SERVER='unix:$PULSE_SOCKET'
      export PULSE_COOKIE='$GAMER_RUNTIME/pulse-cookie'

      export LANG='$LANG'
      export LOCALE_ARCHIVE='/run/current-system/sw/lib/locale/locale-archive'

      ${pkgs.dbus}/bin/dbus-run-session -- steam \"\$@\"
    " -- "$@"

    # Cleanup
    echo "Steam exited. Cleaning up ${gamerUser} processes..."
    sudo -u ${gamerUser} pkill -u ${gamerUser} || true
  '';

  steam-gamer-desktop = pkgs.makeDesktopItem {
    name = "steam-gamer";
    desktopName = "Steam Isolated";
    genericName = "Application for managing and playing games on Steam";
    comment = "Launch Steam in an isolated user environment";
    exec = "${steam-gamer}/bin/steam-gamer";
    icon = "steam";
    categories = [ "Network" "FileTransfer" "Game" ];
  };
in
{
  options.nyx.programs.steam = {
    enable = lib.mkEnableOption "Steam";
    isolation = lib.mkEnableOption "Gamer User Isolation";
  };

  config = lib.mkIf cfg.enable {
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = false;
      dedicatedServer.openFirewall = false;
    };

    users.users.${gamerUser} = lib.mkIf cfg.isolation {
      isNormalUser = true;
      description = "Isolated Gaming User";
      extraGroups = [ "video" "audio" "input" "networkmanager" ];
    };

    security.pam.loginLimits = [
      { domain = "*"; item = "nofile"; type = "soft"; value = "524288"; }
      { domain = "*"; item = "nofile"; type = "hard"; value = "1048576"; }
    ];

    environment.systemPackages = [ pkgs.mangohud ]
      ++ lib.optionals cfg.isolation [ steam-gamer steam-gamer-desktop ];

    security.sudo.extraRules = lib.mkIf cfg.isolation [{
      users = [ mainUser ];
      runAs = gamerUser;
      commands = [{
        command = "ALL";
        options = [ "NOPASSWD" ];
      }];
    }];

    environment.persistence = lib.mkIf imp.enable {
      "${imp.persistentStoragePath}" = {
        users = lib.mkMerge [
          (lib.mkIf cfg.isolation {
            ${gamerUser} = {
              directories = steamDirs ++ [ "Downloads" ];
            };
          })
          (lib.mkIf (!cfg.isolation) {
            ${mainUser} = {
              directories = steamDirs;
            };
          })
        ];
      };
    };
  };
}

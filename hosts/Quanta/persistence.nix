{
  directories = [
    "/var/log"
    "/var/lib/nixos"
    "/var/lib/flatpak"
    "/var/lib/NetworkManager"
    "/var/lib/systemd/coredump"
    "/etc/NetworkManager/system-connections"
  ];

  files = [
    "/etc/machine-id"
    "/etc/adjtime"
  ];

  users = {
    dx = {
      directories = [
        "nixos"
        ".var"
        ".local/share/direnv"
        ".local/share/fish"
        "Downloads"
        "Pictures/Wallpapers"
        ".config/vesktop/"
      ];
      files = [
        ".mozilla/firefox/profiles.ini"
        ".mozilla/firefox/default/key4.db"
        ".mozilla/firefox/default/cookies.sqlite"
      ];
    };
  };
}

{ pkgs, ... }:

{
  services.fstrim.enable = true;

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" "/mnt/storage" "/mnt/vault" ];
  };

  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
  '';

  environment.systemPackages = with pkgs; [
    nvme-cli
    smartmontools
  ];
}

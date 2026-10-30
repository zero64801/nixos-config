{ pkgs, ... }:

{
  fileSystems."/var/lib/samba" = {
    device = "/mnt/storage/samba";
    fsType = "none";
    options = [ "bind" "nofail" ];
    depends = [ "/mnt/storage" ];
  };

  systemd.services.samba-statedir-init = {
    description = "Create the /mnt/storage bind source for /var/lib/samba";
    after = [ "mnt-storage.mount" ];
    before = [ "var-lib-samba.mount" ];
    requiredBy = [ "var-lib-samba.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/mkdir -p /mnt/storage/samba";
    };
  };
}

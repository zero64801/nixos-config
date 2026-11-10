# nix build --impure --no-link -L --expr 'import ./core/_tests/polkit-ask.nix { }'
{
  pkgs ? (builtins.getFlake (toString ../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:

pkgs.testers.runNixOSTest {
  name = "polkit-ask-admin";

  defaults = {
    imports = [ ../polkit.nix ];
    security.polkit.enable = true;
    # Their policies and the rule files they install are what the option has to answer before.
    environment.systemPackages = [
      pkgs.flatpak
      pkgs.udisks2
    ];
    users.users.alice = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    # A session that is active and local, the kind the packages let through.
    services.getty.autologinUser = "alice";
  };

  nodes.stock.my.security.polkitAskAdmin = [ ];
  nodes.asking = { };

  testScript = ''
    start_all()


    def verdict(machine, action):
        shell = machine.succeed("pgrep -u alice -t tty1 | head -1").strip()
        return machine.execute(f"pkcheck --action-id {action} --process {shell} 2>&1")


    for machine in (stock, asking):
        machine.wait_until_succeeds("pgrep -u alice -t tty1", timeout=60)
        machine.wait_until_succeeds("loginctl show-user alice -p State | grep -q active", timeout=30)

    # loop-setup is let through by its policy, modify-repo by the rule Flatpak installs for wheel.
    listed = ["org.freedesktop.udisks2.loop-setup", "org.freedesktop.Flatpak.modify-repo"]

    with subtest("the packages let the active session do these outright"):
        for action in listed:
            status, output = verdict(stock, action)
            assert status == 0, (action, status, output)

    with subtest("listed actions ask for an administrator, the rest are left alone"):
        for action in listed:
            status, output = verdict(asking, action)
            assert status == 2 and "auth_admin" in output, (action, status, output)
        status, output = verdict(asking, "org.freedesktop.udisks2.filesystem-mount")
        assert status == 0, (status, output)
  '';
}

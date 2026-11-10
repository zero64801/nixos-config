# nix build --impure --no-link -L --expr 'import ./core/_tests/kernel.nix { }'
{
  pkgs ? (builtins.getFlake (toString ../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:

let
  # N_HDLC, a line discipline no terminal starts with.
  switchDiscipline = pkgs.writeText "switch-discipline.py" ''
    import fcntl, pty, struct, termios
    fcntl.ioctl(pty.openpty()[1], termios.TIOCSETD, struct.pack("i", 13))
  '';
in
pkgs.testers.runNixOSTest {
  name = "kernel-restrictions";

  defaults = {
    imports = [ ../kernel.nix ];
    users.users.alice.isNormalUser = true;
    environment.systemPackages = [
      pkgs.iproute2
      pkgs.python3
    ];
  };

  # The kernel as it comes, to show that what the other machine refuses is reachable.
  nodes.stock.boot.kernel.sysctl."dev.tty.ldisc_autoload" = 1;

  nodes.restricted.my.security.restrictTrafficControl = {
    enable = true;
    keep = [ "sch_htb" ];
  };

  testScript = ''
    start_all()


    # What any program can do: become the admin of a network of its own and ask for a queueing discipline there.
    def add_qdisc(machine, qdisc):
        return machine.execute(f"su alice -c 'unshare -Urn tc qdisc add dev lo root handle 1: {qdisc}' 2>&1")


    def switch_discipline(machine):
        return machine.execute("su alice -c 'python3 ${switchDiscipline}' 2>&1")


    def loaded(machine, module):
        return machine.execute(f"grep -q '^{module} ' /proc/modules")[0] == 0


    for machine in (stock, restricted):
        machine.wait_for_unit("multi-user.target")
        for module in ("sch_qfq", "sch_htb", "n_hdlc"):
            machine.succeed(f"find -L /run/current-system/kernel-modules/ -name '{module}.ko*' | grep -q .")
            assert not loaded(machine, module), f"{module} is loaded on {machine.name} before anything asked for it"

    with subtest("the stock kernel loads a traffic control module and a line discipline for any user"):
        assert add_qdisc(stock, "qfq")[0] == 0
        assert loaded(stock, "sch_qfq")
        assert switch_discipline(stock)[0] == 0
        assert loaded(stock, "n_hdlc")

    with subtest("a refused traffic control module does not load, and one that is kept does"):
        status, output = add_qdisc(restricted, "qfq")
        assert status != 0 and not loaded(restricted, "sch_qfq"), output
        status, output = add_qdisc(restricted, "htb")
        assert status == 0 and loaded(restricted, "sch_htb"), output
        restricted.fail("modprobe sch_qfq")

    with subtest("a line discipline does not load for a user, and does for root"):
        status, output = switch_discipline(restricted)
        assert status != 0 and not loaded(restricted, "n_hdlc"), output
        restricted.succeed("python3 ${switchDiscipline}")
        assert loaded(restricted, "n_hdlc")
  '';
}

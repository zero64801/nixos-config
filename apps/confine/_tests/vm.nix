# nix build --impure --no-link -L --expr 'import ./apps/confine/_tests/vm.nix { }'
# What the build sandbox cannot show: a user manager to ask for scopes, and pasta with a tap device.
{
  pkgs ? import <nixpkgs> { },
}:

pkgs.testers.runNixOSTest {
  name = "confine";

  # Another machine on the LAN, to tell a forward that names an address from one left on loopback.
  nodes.client = { pkgs, ... }: { environment.systemPackages = [ pkgs.python3 ]; };

  nodes.machine =
    { lib, pkgs, ... }:
    let
      # Every process below an instance's launcher by its executable, marked by whether it sits in the instance's scope.
      tree = pkgs.writeShellScriptBin "confine-tree" ''
        set -euo pipefail
        dirs=(/run/user/1000/confine/"$1".[0-9]*)
        state=''${dirs[0]}/state
        [ -f "$state" ] || { echo "no instance of $1" >&2; exit 1; }
        get() { sed -n "s/^$1=//p" "$state" | tail -n 1; }
        scope=$(get scope)

        walk() {
          local pid=$1 where task kid
          where=$(sed -n 's/^0:://p' "/proc/$pid/cgroup" 2>/dev/null) || return 0
          [ -n "$where" ] || return 0
          if [ "''${where##*/}" = "$scope" ]; then where=inside; else where=outside; fi
          printf '%s %s %s\n' "$where" "$pid" "$(basename "$(readlink "/proc/$pid/exe" 2>/dev/null)")"
          for task in "/proc/$pid/task"/*; do
            for kid in $(cat "$task/children" 2>/dev/null); do
              walk "$kid"
            done
          done
        }

        echo "$scope"
        walk "$(get launcher_pid)"
      '';

      # A network setup may leave a tunnel daemon running, which belongs to the app's scope like the rest.
      lingeringSetup = pkgs.writeShellScript "lingering-setup" ''
        ${pkgs.coreutils}/bin/sleep 3002 < /dev/null > /dev/null 2>&1 &
      '';

      python = pkgs.python3.withPackages (p: [ p.jeepney ]);

      # Answers the portal's file dialog at once with one file, in place of a person at the dialog.
      chooser = pkgs.writeText "chooser.py" ''
        from jeepney import HeaderFields, MessageType, new_error, new_method_return
        from jeepney.bus_messages import message_bus
        from jeepney.io.blocking import open_dbus_connection

        conn = open_dbus_connection(bus="SESSION")
        conn.send_and_get_reply(message_bus.RequestName("org.freedesktop.impl.portal.desktop.chooser"))
        while True:
            msg = conn.receive()
            if msg.header.message_type != MessageType.method_call:
                continue
            member = msg.header.fields.get(HeaderFields.member)
            if member == "OpenFile":
                print("asked by", msg.body[1], flush=True)
                conn.send(new_method_return(msg, "ua{sv}", (0, {"uris": ("as", ["file:///home/alice/outside.txt"])})))
            elif member == "GetAll":
                conn.send(new_method_return(msg, "a{sv}", ({},)))
            else:
                conn.send(new_error(msg, "org.freedesktop.DBus.Error.UnknownMethod"))
      '';
      chooserPortal = pkgs.runCommand "chooser-portal" { } ''
        mkdir -p $out/share/xdg-desktop-portal/portals
        printf '[portal]\nDBusName=org.freedesktop.impl.portal.desktop.chooser\nInterfaces=org.freedesktop.impl.portal.FileChooser;\n' \
          > $out/share/xdg-desktop-portal/portals/chooser.portal
      '';

      shell =
        name: settings:
        {
          package = pkgs.bash;
          binaries = [ "bash" ];
          binPrefix = "${name}-";
        }
        // settings;
    in
    {
      imports = [ ../default.nix ];

      virtualisation.cores = 2;
      virtualisation.memorySize = 2048;

      # Each compositor decides for itself what a security context hides, so the two most used ones that have the
      # protocol run here without a screen, and Weston stands for those that lack it, as GNOME's does.
      hardware.graphics.enable = true;
      systemd.user.services = lib.mapAttrs' (
        name: command:
        lib.nameValuePair "compositor-${name}" {
          wantedBy = [ "default.target" ];
          environment = {
            WLR_BACKENDS = "headless";
            WLR_RENDERER = "pixman";
            WLR_LIBINPUT_NO_DEVICES = "1";
          };
          serviceConfig.ExecStart = command;
        }
      ) {
        kwin = "${pkgs.kdePackages.kwin}/bin/kwin_wayland --virtual --socket wayland-kwin --no-lockscreen --no-global-shortcuts --no-kactivities";
        # Sway names its socket itself, the first free one.
        sway = "${pkgs.sway-unwrapped}/bin/sway --config ${pkgs.writeText "sway-config" ""}";
        weston = "${pkgs.weston}/bin/weston --backend=headless --socket=wayland-weston";
      }
      // {
        chooser = {
          wantedBy = [ "default.target" ];
          serviceConfig.ExecStart = "${python}/bin/python3 ${chooser}";
        };
      };

      boot.kernelModules = [
        "tun"
        "vgem"
      ];
      # pasta copies the host's routes, and without one the gateway check below would have nothing to try.
      networking.defaultGateway = {
        address = "192.168.1.254";
        interface = "eth1";
      };

      # Open for both forwarded ports, so the address a port listens on is all that keeps the LAN out.
      networking.firewall.allowedTCPPorts = [
        8090
        8091
      ];
      networking.firewall.allowedUDPPorts = [ 8091 ];

      # The portal tells a sandboxed caller by the Flatpak identity it finds behind the bus peer, which is confine's proxy.
      xdg.portal = {
        enable = true;
        extraPortals = [
          pkgs.xdg-desktop-portal-gtk
          chooserPortal
        ];
        config.common = {
          default = "gtk";
          "org.freedesktop.impl.portal.FileChooser" = "chooser";
        };
      };

      # The portal only starts inside a graphical session, which no display manager declares here.
      systemd.user.targets.desktop-session = {
        bindsTo = [ "graphical-session.target" ];
        wantedBy = [ "default.target" ];
      };

      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        linger = true;
      };

      environment.systemPackages = [
        python
        tree
      ];

      # Only 8081 is declared to the sandbox, 8082 stands for every other service on the host's loopback.
      systemd.services = lib.genAttrs [ "listener-8081" "listener-8082" ] (name: {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind 127.0.0.1 ${lib.removePrefix "listener-" name}";
          WorkingDirectory = "/var/empty";
          DynamicUser = true;
        };
      });

      confine.apps = {
        plain = shell "plain" { appId = "com.test.Plain"; };

        net = shell "net" {
          appId = "com.test.Net";
          portals = true;
          network = "isolated";
          networkPorts.toHost = [ 8081 ];
          networkSetups.daemon = lingeringSetup;
          dbus.session.call = [ "org.freedesktop.portal.*=*" ];
        };

        offline = shell "offline" {
          appId = "com.test.Offline";
          portals = true;
          dbus.session.call = [ "org.freedesktop.portal.*=*" ];
          dbus.session.broadcast = [ "org.freedesktop.portal.*=@/org/freedesktop/portal/*" ];
          # The portal checks a file it is handed by its path outside, so the folder sits at the same path on both sides.
          binds.rw = [ "shared" ];
        };

        server = shell "server" {
          appId = "com.test.Server";
          network = "isolated";
          networkPorts.fromHost = [
            8090
            "0.0.0.0/8091"
            8092
          ];
        };

        namespaces = shell "namespaces" {
          appId = "com.test.Namespaces";
          network = "isolated";
          seccomp.userns = true;
        };

        # 8082 is taken on the host, so pasta cannot have it.
        clash = shell "clash" {
          appId = "com.test.Clash";
          network = "isolated";
          networkPorts.fromHost = [ 8082 ];
        };

        # Its home sits in a shared folder next to a guarded file, so the launcher pins the folder above both.
        moved = shell "moved" {
          appId = "com.test.Moved";
          home = "ephemeral";
          env.HOME = "/home/alice/work/inner/home";
          binds.rw = [ "/home/alice/work" ];
          binds.ro = [
            "xdg-config/theme"
            "/home/alice/work/inner/guarded"
          ];
        };

        limited = shell "limited" {
          appId = "com.test.Limited";
          resources = {
            MemoryMax = "256M";
            TasksMax = 64;
            CPUQuota = "50%";
          };
        };

        globals = {
          package = pkgs.wayland-utils;
          binaries = [ "wayland-info" ];
          binPrefix = "confined-";
          appId = "com.test.Globals";
          wayland = true;
        };

        uncontexted = {
          package = pkgs.wayland-utils;
          binaries = [ "wayland-info" ];
          binPrefix = "uncontexted-";
          appId = "com.test.Uncontexted";
          wayland = true;
          waylandSecurityContext = false;
        };

        outer = shell "outer" {
          appId = "com.test.Outer";
          seccomp.nesting = true;
        };
      };
    };

  testScript =
    let
      # Two web servers and a UDP echo, each reachable from outside only as far as its forward listens.
      serve = pkgs.writeShellScript "serve" ''
        cd /tmp
        python3 -m http.server 8090 &
        python3 -m http.server 8091 &
        python3 -m http.server --bind 127.0.0.1 8092 &
        exec python3 -c '
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("0.0.0.0", 8091))
        while True:
            data, peer = s.recvfrom(64)
            s.sendto(b"echo " + data, peer)
        '
      '';

      echo = pkgs.writeText "echo.py" ''
        import socket, sys
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(5)
        s.sendto(b"ping", (sys.argv[1], int(sys.argv[2])))
        print(s.recvfrom(64)[0].decode())
      '';

      # Hands the document portal a file from inside a sandbox, which takes a descriptor opened as a bare path.
      addDocument = pkgs.writeText "add-document.py" ''
        import os, subprocess, sys
        fd = os.open(sys.argv[1], os.O_PATH)
        call = ["busctl", "--user", "call", "org.freedesktop.portal.Documents", "/org/freedesktop/portal/documents",
                "org.freedesktop.portal.Documents", "Add", "hbb", str(fd), "false", "false"]
        sys.exit(subprocess.run(call, pass_fds=[fd]).returncode)
      '';

      # Asks the portal for a file from inside a sandbox and prints what its answer names.
      pickFile = pkgs.writeText "pick-file.py" ''
        from jeepney import DBusAddress, MatchRule, new_method_call
        from jeepney.bus_messages import message_bus
        from jeepney.io.blocking import open_dbus_connection

        conn = open_dbus_connection(bus="SESSION")
        path = "/org/freedesktop/portal/desktop/request/" + conn.unique_name[1:].replace(".", "_") + "/pick"
        rule = MatchRule(type="signal", interface="org.freedesktop.portal.Request", member="Response", path=path)
        conn.send_and_get_reply(message_bus.AddMatch(rule))
        portal = DBusAddress("/org/freedesktop/portal/desktop", bus_name="org.freedesktop.portal.Desktop",
                             interface="org.freedesktop.portal.FileChooser")
        with conn.filter(rule) as answers:
            conn.send_and_get_reply(new_method_call(portal, "OpenFile", "ssa{sv}", ("", "Pick", {"handle_token": ("s", "pick")})))
            code, results = conn.recv_until_filtered(answers, timeout=30).body
        uri = results["uris"][1][0]
        print(code, uri, uri.removeprefix("file://"))
      '';

      probe = pkgs.writeShellScript "probe" ''
        try() {
          if timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2> /dev/null; then echo "$3 open"; else echo "$3 closed"; fi
        }
        try 127.0.0.1 8081 declared
        try 127.0.0.1 8082 undeclared
        gateway=$(ip -4 route show default | awk '{ print $3; exit }')
        if [ -n "$gateway" ]; then try "$gateway" 8082 gateway; fi
      '';

      guardProbe = pkgs.runCommandCC "confine-guard-probe" { } ''
        mkdir -p "$out/bin"
        $CC -O1 -Wall -Wextra -Werror -o "$out/bin/guard-probe" ${./guard-probe.c}
      '';

      # Runs an app on a terminal of its own and presses Ctrl+C two seconds in.
      interrupt = pkgs.writeShellScript "interrupt" ''
        (sleep 2; printf '\003'; sleep 5) \
          | script -qec "$1 -c 'trap \"echo got-int\" INT; sleep 4; sleep 1; echo survived'" /dev/null
      '';
    in
    ''
      import shlex

      BIN = "/run/current-system/sw/bin"
      SLICE = "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice"
      SESSION = "XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"


      def unit(arguments):
          return "systemd-run --user -M alice@ --quiet --collect " + arguments


      def start(name, command, options=""):
          machine.succeed(unit(f"--unit={name} {options} -- {command}"))


      def output(command):
          return machine.succeed(unit(f"--wait --pipe -- {command}"))


      def alice(command):
          return machine.succeed("su alice -c " + shlex.quote(f"{SESSION} {command}"))


      def instance(app):
          return f"/run/user/1000/confine/{app}.[0-9]*"


      def wait_running(app):
          machine.wait_until_succeeds(f"grep -q '^pid=' {instance(app)}/state", timeout=30)


      def in_scope(app, expected):
          lines = machine.succeed("confine-tree " + app).splitlines()
          scope, processes = lines[0], [line.split() for line in lines[1:]]
          assert scope.startswith(f"app-confine-{app}-"), f"{app} has no scope: {lines}"
          outside = [p for p in processes if p[0] != "inside"]
          assert not outside, f"outside {scope}: {outside}"
          names = [p[2] for p in processes]
          for name in expected:
              assert any(n.startswith(name) for n in names), f"no {name} among {names}"
          return scope


      def pid_of(app, name):
          lines = machine.succeed("confine-tree " + app).splitlines()[1:]
          return next(line.split()[1] for line in lines if line.split()[2].startswith(name))


      GET_ID = "busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetId"


      def wait_gone(app):
          machine.wait_until_fails(f"ls -d {instance(app)}", timeout=30)
          machine.wait_until_fails(
              f"systemctl --user -M alice@ list-units --all --no-legend 'app-confine-{app}-*' | grep -q .", timeout=30
          )


      start_all()
      machine.wait_for_unit("user@1000.service")
      machine.wait_for_unit("listener-8081.service")
      machine.wait_for_unit("listener-8082.service")
      machine.wait_until_succeeds("timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8082'")

      with subtest("the D-Bus proxy started before the scope joins it, and the delegation carries no controllers"):
          start("plain", f"{BIN}/plain-bash -c 'sleep 3001'")
          wait_running("com.test.Plain")
          scope = in_scope("com.test.Plain", ["confine-launch", "bwrap", "xdg-dbus-proxy", "coreutils"])
          shown = machine.succeed(f"systemctl --user -M alice@ show {scope} -p Delegate -p DelegateControllers")
          assert sorted(shown.split()) == ["Delegate=yes", "DelegateControllers="], shown
          assert machine.succeed(f"cat {SLICE}/{scope}/cgroup.subtree_control").strip() == ""

      with subtest("the D-Bus proxy relays the bus from a sandbox of its own that sees none of the user's files"):
          proxy = pid_of("com.test.Plain", "xdg-dbus-proxy")
          status = machine.succeed(f"grep -E '^(Seccomp|NoNewPrivs):' /proc/{proxy}/status")
          assert status.split() == ["NoNewPrivs:", "1", "Seccomp:", "2"], status
          assert machine.succeed(f"ls /proc/{proxy}/root").split() == ["nix", "run"]
          assert machine.succeed(f"ls /proc/{proxy}/root/run/user/1000").split() == ["bus", "confine"]
          assert machine.succeed(f"ls /proc/{proxy}/root/run/user/1000/confine/*").split() == ["bus"]
          assert machine.succeed(f"readlink /proc/{proxy}/ns/net") != machine.succeed("readlink /proc/1/ns/net")
          assert alice(f"confine enter com.test.Plain {GET_ID}").startswith('s "')

      with subtest("ps, enter and kill reach the running sandbox"):
          assert scope in alice("confine ps")
          status = alice("confine enter com.test.Plain grep -E '^(Seccomp|NoNewPrivs):' /proc/self/status")
          assert status.split() == ["NoNewPrivs:", "1", "Seccomp:", "2"], status
          alice("confine kill com.test.Plain")
          machine.wait_until_fails("pgrep -f '^sleep 3001$'", timeout=30)
          wait_gone("com.test.Plain")

      with subtest("pasta, its far side and what a network setup leaves running join the scope"):
          start("net", f"{BIN}/net-bash -c 'sleep 3007'", "-E CONFINE_NETWORK_SETUP=daemon")
          wait_running("com.test.Net")
          in_scope("com.test.Net", ["confine-launch", "bwrap", "xdg-dbus-proxy", "passt", "coreutils"])
          machine.succeed("pgrep -f 'sleep 300[2]$'")
          assert alice(f"confine enter com.test.Net {GET_ID}").startswith('s "')
          alice("confine kill com.test.Net")
          wait_gone("com.test.Net")
          machine.fail("pgrep -f 'sleep 300[2]$'")
          machine.fail("pgrep -u alice '^pas(st|ta)'")

      with subtest("an isolated app and the host meet only on the declared ports"):
          start("server", f"{BIN}/server-bash ${serve}")
          machine.wait_until_succeeds("timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8090'", timeout=30)
          seen = output(f"{BIN}/net-bash ${probe}").splitlines()
          assert "declared open" in seen, seen
          assert "undeclared closed" in seen, seen
          assert "gateway closed" in seen, seen

      with subtest("a port from the host listens on loopback unless it names an address"):
          listening = machine.succeed("ss -Hltn").split()
          assert "127.0.0.1:8090" in listening and "0.0.0.0:8091" in listening, listening
          assert not [a for a in listening if a.endswith(":8090") and a != "127.0.0.1:8090"], listening
          # A client given the name tries ::1 first, is refused there and falls back, which a listener on ::1 with nothing behind it would not allow.
          machine.succeed("curl --silent --fail --max-time 5 --output /dev/null http://localhost:8090/")

      with subtest("a server that listens on loopback alone inside is reached from the host's loopback"):
          machine.wait_until_succeeds("curl --silent --fail --max-time 5 --output /dev/null http://127.0.0.1:8092/", timeout=30)

      with subtest("another machine reaches a port that names an address and none left on loopback"):
          machine.wait_until_succeeds("timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8091'", timeout=30)
          client.wait_for_unit("multi-user.target")
          client.succeed("timeout 5 bash -c 'exec 3<>/dev/tcp/machine/8091'")
          assert client.succeed("python3 ${echo} machine 8091").strip() == "echo ping"
          client.fail("timeout 5 bash -c 'exec 3<>/dev/tcp/machine/8090'")

      with subtest("a second instance starts without the ports the first holds"):
          second = output(f"{BIN}/server-bash -c 'echo second'")
          assert second == "second\n", second
          machine.succeed("timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8090'")
          alice("confine kill com.test.Server")
          wait_gone("com.test.Server")

      with subtest("a port from the host that is taken stops the launch with pasta's own reason"):
          status, refusal = machine.execute(unit(f"--wait --pipe -- {BIN}/clash-bash -c true 2>&1"))
          assert status != 0 and "Address already in use" in refusal and "kept forking" not in refusal, refusal
          wait_gone("com.test.Clash")

      with subtest("an isolated app that may create namespaces cannot administer a network of its own"):
          # pasta closes what it inherits, so the guard reports over the socket the far side fetched its output on.
          got = output(f"{BIN}/namespaces-bash -c ${guardProbe}/bin/guard-probe").split()
          want = [
              "home-netlink=ok", "own-netlink=EPERM", "own-netlink-generic=EPERM", "early-netlink-tc=EPERM", "ioctl-read=ok",
              "ioctl-interface=EPERM", "ioctl-bridge=EPERM", "raw-socket=EPERM", "tcp-socket=ok", "option-ipsec=EPERM",
              "option-repair=EPERM", "option-plain=ok", "sysctl=EROFS",
          ]
          assert got == want, got
          wait_gone("com.test.Namespaces")

      with subtest("reading an isolated app's output does not wait for what it left running, and it starts with no signal blocked"):
          captured = alice(f"timeout 20 sh -c '{BIN}/net-bash -c \"sleep 3009 < /dev/null > /dev/null 2>&1 & grep SigBlk /proc/self/status\" 2>&1 | cat'")
          assert captured.split() == ["SigBlk:", "0000000000000000"], captured
          machine.succeed("pgrep -f '^sleep 3009$'")
          alice("confine kill com.test.Net")
          wait_gone("com.test.Net")

      with subtest("Ctrl+C is the app's to answer, pasta and bwrap in between do not die of it"):
          answered = alice(f"${interrupt} {BIN}/net-bash")
          assert "got-int" in answered and "survived" in answered, answered
          wait_gone("com.test.Net")

      with subtest("a folder bound into a moved home is not covered by a guard on its shared folder"):
          alice("mkdir -p ~/.config/theme ~/work/inner/home && echo styled > ~/.config/theme/marker && echo kept > ~/work/inner/guarded")
          seen = output(f"{BIN}/moved-bash -c 'cat ~/.config/theme/marker; echo changed 2>/dev/null > /home/alice/work/inner/guarded; cat /home/alice/work/inner/guarded'")
          assert seen == "styled\nkept\n", seen

      with subtest("resource limits sit on the scope"):
          start("limited", f"{BIN}/limited-bash -c 'sleep 3003'")
          wait_running("com.test.Limited")
          scope = in_scope("com.test.Limited", ["confine-launch", "bwrap", "coreutils"])
          for file, value in [("memory.max", "268435456"), ("pids.max", "64"), ("cpu.max", "50000 100000")]:
              found = machine.succeed(f"cat {SLICE}/{scope}/{file}").strip()
              assert found == value, f"{file} is {found}"
          alice("confine kill com.test.Limited")
          wait_gone("com.test.Limited")

      with subtest("a launch returns with its app while what the app left behind runs on in the scope"):
          status, _ = machine.execute(
              unit(f"--wait --unit=lingering -- {BIN}/plain-bash -c 'sleep 3004 < /dev/null > /dev/null 2>&1 & exit 3'")
          )
          assert status == 3, status
          machine.succeed("pgrep -f '^sleep 3004$'")
          in_scope("com.test.Plain", ["confine-launch", "bwrap", "xdg-dbus-proxy", "coreutils"])
          machine.succeed("kill $(pgrep -f '^sleep 3004$')")
          wait_gone("com.test.Plain")

      with subtest("stopping the unit that launched an app takes the sandbox and its helpers along"):
          start("stopped", f"{BIN}/net-bash -c 'sleep 3005'")
          wait_running("com.test.Net")
          machine.succeed("systemctl --user -M alice@ stop stopped.service")
          machine.wait_until_fails("pgrep -f '^sleep 3005$'", timeout=30)
          wait_gone("com.test.Net")
          machine.fail("pgrep -u alice '^pas(st|ta)'")

      with subtest("a launch from outside the user manager's tree, as from a login shell, still gets its scope"):
          machine.succeed(
              "su alice -c " + shlex.quote(f"{SESSION} {BIN}/net-bash -c 'sleep 3006' < /dev/null > /dev/null 2>&1 &")
          )
          wait_running("com.test.Net")
          in_scope("com.test.Net", ["confine-launch", "bwrap", "xdg-dbus-proxy", "passt", "coreutils"])
          alice("confine kill com.test.Net")
          wait_gone("com.test.Net")

      with subtest("a launch inside a sandbox stays in its parent's scope without a complaint"):
          nested = output(f"{BIN}/outer-bash -c \"{BIN}/plain-bash -c 'echo nested' 2>&1\"")
          assert nested == "nested\n", nested

      def globals_of(text):
          return {line.split("'")[1] for line in text.splitlines() if line.startswith("interface: ")}


      def confined_info(socket, binary="confined-wayland-info"):
          return unit(f"--wait --pipe -E WAYLAND_DISPLAY={socket} -- {BIN}/{binary} 2>&1")


      # What each compositor offers a client outside and must keep from one inside. All must exist outside, or a
      # renamed protocol would pass unnoticed.
      compositors = {
          "kwin": (
              "wayland-kwin",
              {
                  "ext_data_control_manager_v1",
                  "kde_lockscreen_overlay_v1",
                  "org_kde_kwin_fake_input",
                  "org_kde_plasma_activation_feedback",
                  "org_kde_plasma_window_management",
                  "zkde_screencast_unstable_v1",
              },
          ),
          "sway": (
              None,
              {
                  "ext_data_control_manager_v1",
                  "ext_image_copy_capture_manager_v1",
                  "ext_session_lock_manager_v1",
                  "zwlr_data_control_manager_v1",
                  "zwlr_export_dmabuf_manager_v1",
                  "zwlr_foreign_toplevel_manager_v1",
                  "zwlr_layer_shell_v1",
                  "zwlr_output_manager_v1",
                  "zwlr_screencopy_manager_v1",
                  "zwlr_virtual_pointer_manager_v1",
                  "zwp_input_method_manager_v2",
                  "zwp_virtual_keyboard_manager_v1",
              },
          ),
      }

      for name, (socket, privileged) in compositors.items():
          with subtest(f"{name} keeps its privileged protocols from a confined client"):
              if socket is None:
                  socket = machine.wait_until_succeeds("ls /run/user/1000 | grep -xE 'wayland-[0-9]+'", timeout=60).strip()
              machine.wait_for_file(f"/run/user/1000/{socket}", timeout=60)
              host = globals_of(alice(f"WAYLAND_DISPLAY={socket} ${pkgs.wayland-utils}/bin/wayland-info"))
              inside = globals_of(machine.succeed(confined_info(socket)))
              machine.succeed(f"systemctl --user -M alice@ is-active compositor-{name}.service")
              assert "wp_security_context_manager_v1" in host - inside, sorted(host - inside)
              assert privileged <= host, f"{name} no longer offers {sorted(privileged - host)}"
              assert not privileged & inside, f"a confined client sees {sorted(privileged & inside)}"
              assert {"wl_compositor", "wl_seat", "xdg_wm_base"} <= inside, sorted(inside)
              assert inside <= host, sorted(inside - host)
              machine.fail("ls /run/user/1000/confine-com.test.Globals.*")

      with subtest("a compositor without security contexts is refused unless the app opts out"):
          machine.wait_for_file("/run/user/1000/wayland-weston", timeout=60)
          host = globals_of(alice("WAYLAND_DISPLAY=wayland-weston ${pkgs.wayland-utils}/bin/wayland-info"))
          assert "wp_security_context_manager_v1" not in host, "Weston gained security contexts, pick another stand-in"
          status, refusal = machine.execute(confined_info("wayland-weston"))
          assert status != 0 and "waylandSecurityContext = false" in refusal, refusal
          inside = globals_of(machine.succeed(confined_info("wayland-weston", "uncontexted-wayland-info")))
          assert inside == host, sorted(host ^ inside)

      PORTAL = "busctl --user call org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.portal"
      DOCUMENTS = "busctl --user call org.freedesktop.portal.Documents /org/freedesktop/portal/documents org.freedesktop.portal.Documents"

      with subtest("an app that starts before the document portal still gets the portal's folder"):
          machine.succeed("systemctl --user -M alice@ set-environment WAYLAND_DISPLAY=wayland-weston")
          machine.succeed("systemctl --user -M alice@ stop xdg-desktop-portal.service xdg-document-portal.service")
          machine.wait_until_fails("findmnt /run/user/1000/doc", timeout=30)
          listed = output(
              f"{BIN}/offline-bash -c 'echo early > $HOME/shared/early.txt && python3 ${addDocument} $HOME/shared/early.txt && ls $XDG_RUNTIME_DIR/doc'"
          )
          machine.succeed("findmnt /run/user/1000/doc")
          assert listed.split('"')[1] in listed.split(), listed

      with subtest("the portal tells a confined app, and whether it has a network, through the proxy's own sandbox"):
          lookup = f"{PORTAL}.ProxyResolver Lookup s http://example.org"
          assert "direct://" in alice(lookup)
          assert "direct://" in output(f"{BIN}/net-bash -c '{lookup}'")
          status, refusal = machine.execute(unit(f"--wait --pipe -- {BIN}/offline-bash -c '{lookup}' 2>&1"))
          assert status != 0 and "not available inside the sandbox" in refusal, refusal

      with subtest("the document portal grants a file to the app that asked, by its id"):
          added = output(f"{BIN}/offline-bash -c 'echo mine > $HOME/shared/mine.txt && python3 ${addDocument} $HOME/shared/mine.txt'")
          document = added.split('"')[1]
          assert "com.test.Offline" in alice(f"{DOCUMENTS} Info s {document}"), added

      with subtest("a file handed over at launch reaches the sandbox through the document portal"):
          alice("sh -c 'echo forwarded > /home/alice/outside.txt'")
          machine.fail(unit(f"--wait --pipe -- {BIN}/offline-bash -c 'cat /home/alice/outside.txt'"))
          seen = output(f"{BIN}/offline-bash -c 'cat \"$1\"' _ @@ /home/alice/outside.txt @@")
          assert seen == "forwarded\n", seen

      with subtest("a file picked in the portal's dialog is handed to the app alone and readable inside"):
          picked = output(
              f"{BIN}/offline-bash -c 'set -- $(python3 ${pickFile}); echo $1 $2; cat $3; ls /home/alice/outside.txt' 2>&1 || true"
          ).splitlines()
          assert picked[0].startswith("0 file:///run/user/1000/doc/") and picked[0].endswith("/outside.txt"), picked
          assert picked[1] == "forwarded" and "No such file" in picked[2], picked
          assert "asked by com.test.Offline" in machine.succeed("journalctl -b --no-pager _SYSTEMD_USER_UNIT=chooser.service")

      with subtest("nothing is left behind"):
          machine.wait_until_fails("pgrep -u alice -f confine-launch", timeout=30)
          assert machine.succeed("ls /run/user/1000/confine").strip() == ""
    '';
}

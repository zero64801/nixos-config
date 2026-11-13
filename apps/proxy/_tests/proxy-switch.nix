# nix build --impure --no-link -L --expr 'import ./apps/proxy/_tests/proxy-switch.nix { }'
# The switch, started by its sockets, against a real VLESS server and a real WireGuard peer, told apart by the address the page sees.
{
  pkgs ? (builtins.getFlake (toString ../../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:

let
  inherit (pkgs) lib;

  uuid = "11111111-2222-4333-8444-555555555555";
  serverAddress = "192.168.1.50";
  tunnelServer = "10.9.0.1";
  tunnelClient = "10.9.0.2";
  idle = "4s";
  ports = {
    vless = 4431;
    wireguard = 51820;
    page = 8080;
    local = 8090;
  };

  # Made for this test only.
  keys = {
    server = {
      private = "CLn3Wi7m7tSIKDm+gBN412Kr6YOUrzACKTuJb8gXT3I=";
      public = "unGcZN1j2F4uNVcCa2M/iGAHRfz5aF3bKSM/5dQ3mWA=";
    };
    client = {
      private = "+Lda+O/AxfeHy3BONRoVv4M7P/xS72SJfilbDdq3EGE=";
      public = "9ZqFohzRJRbib0QjMuaiezWGk49z4fbSMBDXDW422Bo=";
    };
  };

  vlessServer = pkgs.writeText "vless-server.json" (
    builtins.toJSON {
      log.level = "info";
      inbounds = [
        {
          type = "vless";
          listen = "0.0.0.0";
          listen_port = ports.vless;
          users = [ { inherit uuid; } ];
        }
      ];
      outbounds = [ { type = "direct"; } ];
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "proxy-switch";

  nodes.server =
    { pkgs, ... }:
    {
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = serverAddress;
          prefixLength = 24;
        }
      ];
      networking.firewall = {
        allowedTCPPorts = [
          ports.vless
          ports.page
        ];
        allowedUDPPorts = [ ports.wireguard ];
      };

      networking.wireguard.interfaces.wg0 = {
        ips = [ "${tunnelServer}/24" ];
        listenPort = ports.wireguard;
        privateKeyFile = toString (pkgs.writeText "server.key" keys.server.private);
        peers = [
          {
            publicKey = keys.client.public;
            allowedIPs = [ "${tunnelClient}/32" ];
          }
        ];
      };

      systemd.services.vless = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${lib.getExe pkgs.sing-box} run -c ${vlessServer}";
      };
      systemd.services.page = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -I ${./whoami_page.py} ${toString ports.page}";
      };
    };

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [
        ../../confine/default.nix
        ../vless-proxy.nix
        ../wg-proxy.nix
        ../proxy-switch.nix
      ];

      # What the modules expect from the rest of a host.
      options.my.apps.discord.enable = lib.mkEnableOption "the app the tunnelled launcher is added to";
      options.my.persistence.home.directories = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [ ];
      };
      options.hm = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };

      config = {
        boot.kernelModules = [ "tun" ];
        networking.defaultGateway = {
          address = "192.168.1.254";
          interface = "eth1";
        };

        users.users.alice = {
          isNormalUser = true;
          linger = true;
        };
        environment.systemPackages = [ pkgs.curl ];

        environment.etc."proxies/vless.json".text = builtins.toJSON {
          type = "vless";
          server = serverAddress;
          server_port = ports.vless;
          inherit uuid;
        };
        environment.etc."proxies/wg.json".text = builtins.toJSON {
          type = "wireguard";
          address = [ "${tunnelClient}/32" ];
          private_key = keys.client.private;
          peers = [
            {
              address = serverAddress;
              port = ports.wireguard;
              public_key = keys.server.public;
              allowed_ips = [ "0.0.0.0/0" ];
            }
          ];
        };

        my.apps.vlessProxy = {
          enable = true;
          outboundFile = "/etc/proxies/vless.json";
          socks.idleTimeout = idle;
        };
        my.apps.wgProxy = {
          enable = true;
          endpointFile = "/etc/proxies/wg.json";
          tunnelDns = tunnelServer;
          idleTimeout = idle;
        };
        my.apps.proxySwitch = {
          enable = true;
          idleTimeout = idle;
        };

        # A service on the loopback of the machine the switch runs on, which no route may hand out.
        networking.hosts."127.0.0.1" = [ "loop.test" ];
        systemd.services.local-page = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -I ${./whoami_page.py} ${toString ports.local} 127.0.0.1";
        };

        confine.apps.switcher = {
          package = pkgs.bash;
          binaries = [ "bash" ];
          binPrefix = "switcher-";
          appId = "com.test.Switcher";
          network = "isolated";
          networkPorts.toHost = with config.my.apps.proxySwitch; [
            port
            controlPort
          ];
          binds.ro = [ "xdg-run/proxy-switch" ];
        };
      };
    };


  testScript =
    { nodes, ... }:
    let
      apps = nodes.machine.my.apps;
      switch = apps.proxySwitch;
    in
    ''
      from datetime import timedelta

      PAGE = "http://${serverAddress}:${toString ports.page}/"
      LOCAL = "http://127.0.0.1:${toString ports.local}/"
      SWITCH = "http://127.0.0.1:${toString switch.port}"
      CONTROL = "http://127.0.0.1:${toString switch.controlPort}/configs"
      USER = "systemctl --user -M alice@"
      RUN = "systemd-run --user -M alice@ --quiet --collect --wait --pipe --"
      BIN = "/run/current-system/sw/bin"
      ROUTE = f"{RUN} {BIN}/proxy-route"
      VLESS = "sing-box-vless-socks.service"
      WG = "sing-box-wg-proxy.service"
      RUNNING = "pgrep -f 'sing-box [r]un|systemd-socket-[p]roxyd'"


      def route(name=""):
          return machine.succeed(f"{ROUTE} {name}").strip()


      def seen(proxy=SWITCH):
          """The address the page sees a request through a proxy come from."""
          return machine.succeed(f"curl -s -m 10 -x {proxy} {PAGE}")


      def status(url):
          """The HTTP status of a request through the switch, 000 where there was none."""
          return machine.execute(f"curl -s -o /dev/null -m 5 -w '%{{http_code}}' -x {SWITCH} {url}")[1].strip()


      def active(unit):
          return machine.execute(f"{USER} is-active {unit}")[0] == 0


      def wait_idle():
          machine.wait_until_fails(RUNNING, timeout=timedelta(seconds=30))


      start_all()
      # The WireGuard peer is only added once the network is online, after the units that serve.
      server.wait_for_unit("multi-user.target")
      server.wait_until_succeeds("wg show wg0 peers | grep -q .")
      server.wait_for_open_port(${toString ports.page})
      machine.wait_for_open_port(${toString ports.local})
      # Not their ports, a connection to one would start what is behind it.
      for unit in ["proxy-switch-relay", "proxy-switch-control", "sing-box-vless-socks-relay", "sing-box-wg-proxy-relay"]:
          machine.wait_for_unit(f"{unit}.socket", "alice")
      own = machine.succeed("ip -4 -o addr show dev eth1 | awk '{print $4}' | cut -d/ -f1").strip()

      with subtest("nothing runs before the first connection"):
          machine.fail(RUNNING)
          machine.succeed("test -s /run/user/1000/proxy-switch/secret")

      with subtest("the first connection starts the switch and nothing else, on the default route"):
          assert seen() == own, seen()
          assert active("proxy-switch.service")
          assert not active(VLESS) and not active(WG)
          assert route() == "off", route()

      with subtest("each route starts its own proxy and leaves through it"):
          assert route("vless") == "vless"
          assert seen() == "${serverAddress}", seen()
          assert active(VLESS) and not active(WG)
          assert route("wg") == "wg"
          assert seen() == "${tunnelClient}", seen()
          assert active(WG)
          assert route("off") == "off"
          assert seen() == own, seen()

      with subtest("the direct route refuses the loopback of its own machine, by address and by name"):
          assert machine.succeed(f"curl -s -m 5 {LOCAL}") == "127.0.0.1"
          for host in ["127.0.0.1", "loop.test", "localhost", "0.0.0.0", "[::ffff:127.0.0.1]"]:
              assert status(f"http://{host}:${toString ports.local}/") != "200", host

      with subtest("the control API refuses a request without the secret, proxy-route an unknown route"):
          code = machine.succeed(
              f"curl -s -o /dev/null -w '%{{http_code}}' -X PATCH -d '{{\"mode\":\"vless\"}}' {CONTROL}"
          )
          assert code == "401", code
          machine.fail(f"{ROUTE} direct")
          assert route() == "off"

      with subtest("everything stops once idle, and comes back on the picked route"):
          route("vless")
          assert seen() == "${serverAddress}"
          wait_idle()
          assert route() == "vless", route()
          assert seen() == "${serverAddress}", seen()

      with subtest("it stays up for as long as a connection is open"):
          route("off")
          machine.succeed(f"curl -s -o /tmp/held -m 30 -x {SWITCH} {PAGE}wait/9 >/dev/null 2>&1 &")
          machine.sleep(7)
          assert active("proxy-switch.service") and active("proxy-switch-relay.service")
          machine.wait_until_succeeds(f"test \"$(cat /tmp/held)\" = {own}", timeout=timedelta(seconds=15))
          wait_idle()

      with subtest("a switch cuts a connection opened on the old route"):
          route("wg")
          machine.succeed(
              f"(curl -s -o /dev/null -m 50 -w '%{{http_code}}' -x {SWITCH} {PAGE}wait > /tmp/inflight; echo >> /tmp/inflight) >/dev/null 2>&1 &"
          )
          server.wait_until_succeeds("ss -Htn state established '( sport = :${toString ports.page} )' | grep -q ${tunnelClient}")
          route("off")
          # The page holds the request for a minute, so an end within seconds is the switch closing it.
          machine.wait_until_succeeds("grep -q . /tmp/inflight", timeout=timedelta(seconds=15))
          ended = machine.succeed("head -n 1 /tmp/inflight").strip()
          assert ended != "200", ended

      with subtest("a proxy that something else stops comes back for its route"):
          route("wg")
          assert seen() == "${tunnelClient}"
          machine.succeed(f"{USER} stop {WG}")
          machine.wait_until_succeeds(f"test \"$(curl -s -m 5 -x {SWITCH} {PAGE})\" = ${tunnelClient}", timeout=timedelta(seconds=30))

      with subtest("the proxies behind the routes answer on their own ports, started the same way"):
          wait_idle()
          assert seen("socks5h://${apps.vlessProxy.socks.listen}:${toString apps.vlessProxy.socks.port}") == "${serverAddress}"
          assert seen("http://${apps.wgProxy.listen}:${toString apps.wgProxy.port}") == "${tunnelClient}"
          assert not active("proxy-switch.service")

      with subtest("a sandbox with the ports and the secret bound switches and uses the route, but not the loopback behind it"):
          out = machine.succeed(
              f"{RUN} {BIN}/switcher-bash -c '{BIN}/proxy-route vless && {BIN}/curl -s -m 10 -x {SWITCH} {PAGE}'"
          )
          assert out.split() == ["vless", "${serverAddress}"], out
          out = machine.succeed(
              f"{RUN} {BIN}/switcher-bash -c '{BIN}/proxy-route off && {BIN}/curl -s -o /dev/null -m 5 -w %{{http_code}} -x {SWITCH} {LOCAL}'"
          )
          assert out.split()[0] == "off" and out.split()[1] != "200", out

      with subtest("a route whose proxy cannot start fails instead of going direct, and returns with it"):
          route("vless")
          machine.succeed("rm /etc/proxies/vless.json")
          machine.succeed(f"{USER} stop {VLESS}")
          assert status(PAGE) != "200", status(PAGE)
          machine.succeed("ln -s /etc/static/proxies/vless.json /etc/proxies/vless.json")
          machine.wait_until_succeeds(f"test \"$(curl -s -m 5 -x {SWITCH} {PAGE})\" = ${serverAddress}", timeout=timedelta(seconds=30))
          route("off")
          assert seen() == own
    '';
}

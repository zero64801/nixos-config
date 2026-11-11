# nix build --impure --no-link -L --expr 'import ./apps/proxy/_tests/vless-fallback.nix { }'
# The tunnelled launcher against two real VLESS servers, which needs a tun device and a second machine.
{
  pkgs ? (builtins.getFlake (toString ../../..)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:

let
  inherit (pkgs) lib;

  uuid = "11111111-2222-4333-8444-555555555555";
  serverAddress = "192.168.1.50";
  ports = {
    primary = 4431;
    fallback = 4432;
    page = 8080;
    check = 8081;
  };

  vlessServer =
    port:
    pkgs.writeText "vless-server.json" (
      builtins.toJSON {
        log.level = "info";
        inbounds = [
          {
            type = "vless";
            listen = "0.0.0.0";
            listen_port = port;
            users = [ { inherit uuid; } ];
          }
        ];
        outbounds = [ { type = "direct"; } ];
      }
    );

  outbound =
    port:
    builtins.toJSON {
      type = "vless";
      server = serverAddress;
      server_port = port;
      inherit uuid;
    };

  # What the module expects from the rest of a host, and an app standing in for Discord.
  client =
    fallbacks:
    { pkgs, ... }:
    {
      imports = [
        ../../confine/default.nix
        ../vless-proxy.nix
      ];

      options.my.apps.discord.enable = lib.mkEnableOption "the app the tunnelled launcher is added to";
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

        environment.etc."vless/primary.json".text = outbound ports.primary;
        environment.etc."vless/fallback.json".text = outbound ports.fallback;

        my.apps.discord.enable = true;
        my.apps.vlessProxy = {
          enable = true;
          outboundFile = "/etc/vless/primary.json";
          fallback = {
            outboundFiles = fallbacks;
            checkUrl = "http://${serverAddress}:${toString ports.check}/";
            checkInterval = "3s";
          };
        };

        confine.apps.discord = {
          package = pkgs.bash;
          binaries = [ "bash" ];
          binPrefix = "discord-";
          appId = "com.test.Discord";
          network = "isolated";
        };
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "vless-fallback";

  nodes.server =
    { pkgs, ... }:
    {
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = serverAddress;
          prefixLength = 24;
        }
      ];
      networking.firewall.allowedTCPPorts = lib.attrValues ports;

      systemd.services =
        lib.genAttrs [ "primary" "fallback" ] (name: {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${lib.getExe pkgs.sing-box} run -c ${vlessServer ports.${name}}";
        })
        // lib.genAttrs [ "page" "check" ] (name: {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -I ${./slow_page.py} ${toString ports.${name}}";
        });
    };

  nodes.machine = client [ "/etc/vless/fallback.json" ];
  nodes.single = client [ ];

  testScript = ''
    PAGE = "http://${serverAddress}:${toString ports.page}/"
    LOG = "/home/alice/.local/share/confine/com.test.Discord/fetched"
    RUN = "systemd-run --user -M alice@ --quiet --collect --setenv=CONFINE_NETWORK_SETUP=vless"
    BASH = "/run/current-system/sw/bin/discord-bash"


    def carried(name):
        """How many page fetches this server has relayed."""
        return int(server.succeed(f"journalctl --sync; journalctl -u {name} | grep -c 'inbound connection to ${serverAddress}:${toString ports.page}' || true"))


    def fetched(node):
        return node.succeed(
            f"{RUN} --wait --pipe -- {BASH} -c 'curl -s -m 5 -o /dev/null -w %{{http_code}} {PAGE}'"
        )


    def fetches():
        return int(machine.succeed(f"grep -c 204 {LOG} || true"))


    start_all()
    for unit in ["primary", "fallback", "page", "check"]:
        server.wait_for_unit(unit)
    for port in [${lib.concatMapStringsSep ", " toString (lib.attrValues ports)}]:
        server.wait_for_open_port(port)
    machine.wait_for_unit("user@1000.service")
    single.wait_for_unit("user@1000.service")

    with subtest("without a fallback the tunnel goes out through its one server"):
        assert fetched(single) == "204"
        assert carried("primary") == 1 and carried("fallback") == 0

    with subtest("with both servers up the first one carries the traffic"):
        machine.succeed(
            f"{RUN} --unit=tunnelled -- {BASH} -c "
            f"'while true; do curl -s -m 3 -o /dev/null -w \"%{{http_code}}\\n\" {PAGE} >> ~/fetched; sleep 1; done'"
        )
        machine.wait_until_succeeds(f"test $(grep -c 204 {LOG}) -ge 8", timeout=60)
        assert carried("primary") >= 8, carried("primary")
        assert carried("fallback") == 0, carried("fallback")

    with subtest("the running tunnel moves to the fallback when the first server stops"):
        server.succeed("systemctl stop primary")
        before = fetches()
        machine.wait_until_succeeds(f"test $(grep -c 204 {LOG}) -ge {before + 5}", timeout=60)
        assert carried("fallback") >= 5, carried("fallback")

    with subtest("it stays on the fallback when the first server returns"):
        server.succeed("systemctl start primary")
        server.wait_for_open_port(${toString ports.primary})
        machine.sleep(8)
        primary, before = carried("primary"), fetches()
        machine.wait_until_succeeds(f"test $(grep -c 204 {LOG}) -ge {before + 5}", timeout=60)
        assert carried("primary") == primary, "moved back while the fallback still answered"

    with subtest("it returns to the first server when the fallback stops"):
        server.succeed("systemctl stop fallback")
        primary, before = carried("primary"), fetches()
        machine.wait_until_succeeds(f"test $(grep -c 204 {LOG}) -ge {before + 5}", timeout=60)
        assert carried("primary") >= primary + 5, carried("primary")
        server.succeed("systemctl start fallback")
        server.wait_for_open_port(${toString ports.fallback})

    with subtest("a launch while the first server is down goes out through the fallback"):
        machine.succeed("systemctl --user -M alice@ stop tunnelled")
        server.succeed("systemctl stop primary")
        primary, fallback = carried("primary"), carried("fallback")
        # Until the first test of the servers is in, which takes one fetch, a connection still goes to the first one.
        machine.succeed(
            f"{RUN} --wait --pipe -- {BASH} -c 'for attempt in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 3 -o /dev/null {PAGE} && exit 0; sleep 0.5; done; exit 1'"
        )
        assert carried("fallback") == fallback + 1, carried("fallback")
        assert carried("primary") == primary, carried("primary")
  '';
}

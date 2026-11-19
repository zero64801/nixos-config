# nix build --no-link -L .#tests.lab.keys-scan
# guest-net keys scan on a guest without Windows: the secrets of two TLS connections the guest's openssl holds open, found in its RAM from outside, and those of a curl that connects while the scan follows the capture and is gone before they are checked. Each has to equal what the client itself wrote to its key log.
{
  host,
}:

let
  inherit (host) pkgs;

  # Made for this test only, for tls.test.
  certificate = pkgs.runCommand "tls-test-certificate" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $out/key.pem -out $out/cert.pem -days 3650 \
      -subj /CN=tls.test -addext subjectAltName=DNS:tls.test
  '';

  # Two connections that send a request and stay open, one of TLS 1.3 and one of TLS 1.2, each with its key log.
  held = pkgs.writeText "held.sh" ''
    # Otherwise the clients keep the agent's output open and guest-exec waits out its time limit.
    exec < /dev/null > /dev/null 2>&1
    for version in 1_3 1_2; do
      (printf 'GET / HTTP/1.1\r\nHost: tls.test\r\n\r\n'; sleep 120) |
        openssl s_client -connect 10.9.9.1:8443 -servername tls.test -tls$version -keylogfile /tmp/held$version.log -quiet > /dev/null 2>&1 &
    done
    sleep 3
  '';

  # Answers after a second and closes, so that the client lives long enough to be held still and no longer.
  slow = pkgs.writeText "slow.py" ''
    import socket, ssl, threading, time
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain("${certificate}/cert.pem", "${certificate}/key.pem")
    listener = socket.create_server(("10.9.9.1", 9443))

    def answer(connection):
        with context.wrap_socket(connection, server_side=True) as tls:
            tls.recv(4096)
            time.sleep(1)
            tls.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nslow\n")

    while True:
        threading.Thread(target=answer, args=(listener.accept()[0],), daemon=True).start()
  '';
in
host.needs [ "modules/virtualisation/inspect" ] (
  import ../../inspect/_tests/fixture.nix { inherit host; } {
    name = "keys-scan";
    network = true;
    lab = true;

    machine = {
      environment.systemPackages = [
        pkgs.curl
        pkgs.python3
      ];
      services.nginx = {
        enable = true;
        virtualHosts."tls.test" = {
          onlySSL = true;
          listen = [
            {
              addr = "0.0.0.0";
              port = 8443;
              ssl = true;
            }
          ];
          sslCertificate = "${certificate}/cert.pem";
          sslCertificateKey = "${certificate}/key.pem";
          # The held connections have to outlive the whole test, and nginx closes idle ones after 65 seconds.
          extraConfig = "keepalive_timeout 600s;";
          root = pkgs.writeTextDir "index.html" "behind TLS";
        };
      };
    };

    testScript = ''
      machine.succeed(
          "systemd-run --unit=slow python3 ${slow}",
          "install -d -o alice /tmp/work/out",
      )
      machine.wait_for_unit("nginx.service")
      machine.wait_until_succeeds("curl -skf --resolve tls.test:9443:10.9.9.1 https://tls.test:9443/", timeout=30)
      start_driven()

      script = "; ".join([
          "guest-push ${held} /tmp/held.sh > /dev/null && guest-exec /bin/sh /tmp/held.sh > /dev/null",
          "echo == around; guest-net keys scan --physical",
          "echo == deep; guest-net keys scan --physical --deep",
          "echo == follow; (guest-net keys scan --follow --physical --pause --seconds 15 &"
          " sleep 3; guest-exec --shell 'SSLKEYLOGFILE=/tmp/short.log curl -sk --resolve tls.test:9443:10.9.9.1 https://tls.test:9443/' > /dev/null; wait)",
          "echo == held; guest-exec --shell 'cat /tmp/held1_3.log /tmp/held1_2.log'",
          "echo == short; guest-exec --shell 'cat /tmp/short.log'",
          "echo == tls; guest-net tls",
          "echo == keys; cat $VM_INSPECT_CAPTURE/keys.log",
      ])
      out = machine.succeed(lab(f"cd /tmp/work && vm-inspect --net --control --gdb driven -- sh -c {shlex.quote('{ ' + script + '; } 2>&1')} 2>&1"))
      print(out)
      section = {}
      for part in out.split("== ")[1:]:
          name, _, said = part.partition("\n")
          section[name.strip()] = said

      def secrets(text, only=None):
          lines = {line.strip() for line in text.splitlines() if re.fullmatch(r"[A-Z_0-9]+ [0-9a-f]{64} [0-9a-f]+", line.strip())}
          return {line for line in lines if only is None or line.split()[0] in only}

      traffic = ("CLIENT_TRAFFIC_SECRET_0", "SERVER_TRAFFIC_SECRET_0", "CLIENT_RANDOM")
      everything = secrets(section["held"] + section["short"])
      found = secrets(section["keys"])
      held, short = secrets(section["held"], traffic), secrets(section["short"], traffic)

      with subtest("every secret found is one a client wrote, so nothing false reaches the capture"):
          assert found and found <= everything, found - everything

      with subtest("the traffic secrets of the held connections are found in the RAM, TLS 1.3's around its client random"):
          assert len({line.split()[1] for line in held}) == 2 and len(held) == 3, section["held"]
          assert held <= found, f"missing {held - found}: {section['around']} {section['deep']}"
          assert re.search(r"TLS 1\.3  CLIENT_TRAFFIC_SECRET_0 at 0x[0-9a-f]+, SERVER_TRAFFIC_SECRET_0 at", section["around"]), section["around"]

      with subtest("following the capture, curl's keys are found though curl is gone before they are checked"):
          assert len(short) == 2 and short <= found, f"missing {short - found}: {section['follow']}"
          assert re.search(r"10\.9\.9\.50:\d+ -> 10\.9\.9\.1:9443 .*TLS 1\.3 .*CLIENT_TRAFFIC_SECRET_0, SERVER_TRAFFIC_SECRET_0 in the guest's RAM", section["follow"]), section["follow"]

      with subtest("the flows read as decrypted"):
          assert section["tls"].count("decrypted") >= 3, section["tls"]
    '';
  }
)

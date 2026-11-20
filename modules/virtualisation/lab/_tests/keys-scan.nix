# nix build --no-link -L .#tests.lab.keys-scan
# guest-net keys scan on a guest without Windows: the secrets of two TLS connections the guest's openssl holds open, found in its RAM from outside and in its own memory through its page map, and those of a curl that connects while the scan follows the capture and is gone before they are checked. Each has to equal what the client itself wrote to its key log.
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

  # Two connections that send a request and stay open, one of TLS 1.3 and one of TLS 1.2, each with its key log, and one of
  # TLS 1.3 that updates its keys both ways before its request, which s_client does only without -quiet.
  held = pkgs.writeText "held.sh" ''
    # Otherwise the clients keep the agent's output open and guest-exec waits out its time limit.
    exec < /dev/null > /dev/null 2>&1
    for version in 1_3 1_2; do
      (printf 'GET / HTTP/1.1\r\nHost: tls.test\r\n\r\n'; sleep 120) |
        openssl s_client -connect 10.9.9.1:8443 -servername tls.test -tls$version -keylogfile /tmp/held$version.log -quiet > /dev/null 2>&1 &
    done
    (sleep 1; printf 'K\n'; sleep 1; printf 'GET /updated HTTP/1.1\r\nHost: tls.test\r\n\r\n'; sleep 120) |
      openssl s_client -connect 10.9.9.1:8443 -servername tls.test -tls1_3 -keylogfile /tmp/heldupd.log > /dev/null 2>&1 &
    sleep 4
  '';

  # A server of HTTP/3 that answers every request with a page of its own, after a second, so that the client lives long enough
  # to be held still, as slow.py does for TCP.
  quicServer = pkgs.writeText "quic.py" ''
    import asyncio
    from aioquic.asyncio import QuicConnectionProtocol, serve
    from aioquic.h3.connection import H3_ALPN, H3Connection
    from aioquic.h3.events import DataReceived, HeadersReceived
    from aioquic.quic.configuration import QuicConfiguration

    class Server(QuicConnectionProtocol):
        h3 = None

        def answer(self, stream):
            self.h3.send_headers(stream, [(b":status", b"200"), (b"content-type", b"text/plain")])
            self.h3.send_data(stream, b"over HTTP/3\n", end_stream=True)
            self.transmit()

        def quic_event_received(self, event):
            self.h3 = self.h3 or H3Connection(self._quic)
            for e in self.h3.handle_event(event):
                if isinstance(e, (HeadersReceived, DataReceived)) and e.stream_ended:
                    asyncio.get_running_loop().call_later(1, self.answer, e.stream_id)

    async def main():
        configuration = QuicConfiguration(alpn_protocols=H3_ALPN, is_client=False)
        configuration.load_cert_chain("${certificate}/cert.pem", "${certificate}/key.pem")
        await serve("10.9.9.1", 8444, configuration=configuration, create_protocol=Server)
        await asyncio.Event().wait()

    asyncio.run(main())
  '';

  # Answers after a second and closes, so that the client lives long enough to be held still and no longer, and what trace
  # starts after three, so that its connection is seen by the owners sampled meanwhile.
  slow = pkgs.writeText "slow.py" ''
    import socket, ssl, threading, time
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain("${certificate}/cert.pem", "${certificate}/key.pem")
    listener = socket.create_server(("10.9.9.1", 9443))

    def answer(connection):
        with context.wrap_socket(connection, server_side=True) as tls:
            asked = tls.recv(4096)
            time.sleep(3 if b"/traced" in asked else 1)
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
        (pkgs.python3.withPackages (packages: [ packages.aioquic ]))
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
          "systemd-run --unit=quic python3 ${quicServer}",
          "install -d -o alice /tmp/work/out",
      )
      machine.wait_for_unit("nginx.service")
      machine.wait_until_succeeds("curl -skf --resolve tls.test:9443:10.9.9.1 https://tls.test:9443/", timeout=30)
      start_driven()

      script = "; ".join([
          "guest-push ${held} /tmp/held.sh > /dev/null && guest-exec /bin/sh /tmp/held.sh > /dev/null",
          "echo == around; guest-net keys scan --physical",
          "echo == deep; guest-net keys scan --physical --deep",
          "echo == process; guest-net keys scan --again",
          "echo == follow; (guest-net keys scan --follow --physical --pause --seconds 15 &"
          " sleep 3; guest-exec --shell 'SSLKEYLOGFILE=/tmp/short.log curl -sk --resolve tls.test:9443:10.9.9.1 https://tls.test:9443/' > /dev/null;"
          " guest-exec --shell 'SSLKEYLOGFILE=/tmp/quic.log curl -sk --http3-only --max-time 3 --resolve tls.test:8444:10.9.9.1 https://tls.test:8444/over' > /dev/null; wait)",
          "echo == trace; guest-net trace --physical --pause --agent --seconds 20 -- /bin/sh -c"
          " 'SSLKEYLOGFILE=/tmp/traced.log curl -sk --resolve tls.test:9443:10.9.9.1 https://tls.test:9443/traced'",
          "echo == traced; guest-exec --shell 'cat /tmp/traced.log'",
          "echo == held; guest-exec --shell 'cat /tmp/held1_3.log /tmp/held1_2.log'",
          "echo == short; guest-exec --shell 'cat /tmp/short.log'",
          "echo == quic; guest-exec --shell 'cat /tmp/quic.log'",
          "echo == tls; guest-net tls",
          "echo == http3; guest-net http --host tls.test && guest-net http $(guest-net http | grep 'GET https://tls.test:8444/over' | cut -d' ' -f1)",
          "echo == keys; cat $VM_INSPECT_CAPTURE/keys.log",
          "echo == updated; cat $VM_INSPECT_CAPTURE/updated.log; echo == upd; guest-exec --shell 'cat /tmp/heldupd.log'",
          "echo == late; for f in $(guest-net flows | grep ':8443 ' | cut -d' ' -f1); do"
          " guest-net stream $f --decrypted 2>&1 | grep -q 'GET /updated' && guest-net stream $f --decrypted; done; true",
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
      everything = secrets(section["held"] + section["short"] + section["quic"] + section["traced"])
      found = secrets(section["keys"])
      held, short = secrets(section["held"], traffic), secrets(section["short"], traffic)

      with subtest("every secret found is one a client wrote, so nothing false reaches the capture"):
          assert found and found <= everything, found - everything

      with subtest("the traffic secrets of the held connections are found in the RAM, TLS 1.3's around its client random"):
          assert len({line.split()[1] for line in held}) == 2 and len(held) == 3, section["held"]
          assert held <= found, f"missing {held - found}: {section['around']} {section['deep']}"
          assert re.search(r"TLS 1\.3  CLIENT_TRAFFIC_SECRET_0 at 0x[0-9a-f]+, SERVER_TRAFFIC_SECRET_0 at", section["around"]), section["around"]

      with subtest("without --physical the program itself is read, through its page map, which finds TLS 1.2's secret as well"):
          assert re.search(r"TLS 1\.3  CLIENT_TRAFFIC_SECRET_0 at 0x[0-9a-f]+, SERVER_TRAFFIC_SECRET_0 at", section["process"]), section["process"]
          assert re.search(r"TLS 1\.2  CLIENT_RANDOM at 0x[0-9a-f]+", section["process"]), section["process"]
          assert re.search(r"guest-net: openssl\[\d+\]: ", section["process"]), section["process"]

      with subtest("following the capture, curl's keys are found though curl is gone before they are checked"):
          assert len(short) == 2 and short <= found, f"missing {short - found}: {section['follow']}"
          assert re.search(r"10\.9\.9\.50:\d+ -> 10\.9\.9\.1:9443 .*TLS 1\.3 .*CLIENT_TRAFFIC_SECRET_0, SERVER_TRAFFIC_SECRET_0 in the guest's RAM", section["follow"]), section["follow"]

      with subtest("following the capture, a QUIC connection's keys are found too, read from its Initial packets and the RAM"):
          quic = secrets(section["quic"], traffic)
          assert len(quic) == 2 and quic <= found, f"missing {quic - found}: {section['follow']}"
          assert re.search(r"10\.9\.9\.50:\d+ -> 10\.9\.9\.1:8444  tls\.test  QUIC  CLIENT_TRAFFIC_SECRET_0, SERVER_TRAFFIC_SECRET_0", section["follow"]), section["follow"]

      with subtest("the HTTP/3 of the QUIC connection is read with the secrets found, though tshark reads it only with the handshake's"):
          assert re.search(r"GET https://tls\.test:8444/over -> 200 in \d+ ms text/plain", section["http3"]), section["http3"]
          assert "over HTTP/3" in section["http3"] and "user-agent: curl" in section["http3"], section["http3"]

      with subtest("trace starts a program with the scan already following, and shows its flows and those of what it started"):
          traced = secrets(section["traced"], traffic)
          assert len(traced) == 2 and traced <= found, f"missing {traced - found}: {section['trace']}"
          started = section["flows of sh and what it started"]
          assert re.search(r"10\.9\.9\.50:\d+ -> 10\.9\.9\.1:9443 .* curl\[\d+\]", started), started
          assert "decrypted" in section["handshakes"], section["handshakes"]

      with subtest("after a key update both ways the newest secrets are found, kept apart, and open the flow from the update on"):
          random = next(line.split()[1] for line in section["upd"].splitlines() if line.startswith("CLIENT_TRAFFIC_SECRET_0"))
          assert f"CLIENT_TRAFFIC_SECRET_1 {random} " in section["updated"] and f"SERVER_TRAFFIC_SECRET_1 {random} " in section["updated"], section["updated"]
          assert re.search(r"TLS 1\.3 after key updates  CLIENT_TRAFFIC_SECRET_1 at 0x[0-9a-f]+, SERVER_TRAFFIC_SECRET_1 at", section["around"]), section["around"]
          assert "GET /updated HTTP/1.1" in section["late"] and "404 Not Found" in section["late"], section["late"]

      with subtest("the flows read as decrypted"):
          assert section["tls"].count("decrypted") >= 3, section["tls"]
    '';
  }
)

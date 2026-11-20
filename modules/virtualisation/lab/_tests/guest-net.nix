# nix build --no-link -L .#tests.lab.guest-net
# guest-net on what a session recorded of a guest that looked up a name, fetched a page, fetched one over HTTP/2 with TLS while writing its keys, kept a connection open and sent a request meant to steer a terminal.
{
  host,
}:

let
  inherit (host) pkgs;
  tshark = "${pkgs.wireshark-cli}/bin/tshark";

  # Made for this test only, for tls.test.
  certificate = pkgs.runCommand "tls-test-certificate" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $out/key.pem -out $out/cert.pem -days 3650 \
      -subj /CN=tls.test -addext subjectAltName=DNS:tls.test
  '';

  # A page of JSON that nginx sends compressed, a JSON request of HTTP/2 and a form of HTTP/1, each with a body to read back.
  site = pkgs.runCommand "tls-test-site" { } ''
    mkdir $out
    printf %s "the secret behind TLS" > $out/secret.txt
    echo '{"name": "site", "list": [1, 2]}' > $out/data.json
  '';
  posts = pkgs.writeText "posts.sh" ''
    export SSLKEYLOGFILE=/tmp/keys.log
    curl -sk --http2 --compressed --resolve tls.test:8443:10.9.9.1 -o /dev/null https://tls.test:8443/data.json
    curl -sk --http2 --resolve tls.test:8443:10.9.9.1 -o /dev/null -H 'content-type: application/json' \
      --data '{"user":"alice","pin":1234}' https://tls.test:8443/data.json
    wget -q -O /dev/null --post-data 'name=alice&pin=1234' http://site.test:8000/form || true
  '';

  # A request whose path would clear a terminal that printed it as it is.
  steering = pkgs.writeText "steering.sh" ''
    printf 'GET /\033[2Jcleared HTTP/1.0\r\nHost: evil\r\n\r\n' | nc 10.9.9.1 8000
  '';
in
host.needs [ "modules/virtualisation/inspect" ] (
  import ../../inspect/_tests/fixture.nix { inherit host; } {
    name = "guest-net";
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
          http2 = true;
          listen = [
            {
              addr = "0.0.0.0";
              port = 8443;
              ssl = true;
            }
          ];
          sslCertificate = "${certificate}/cert.pem";
          sslCertificateKey = "${certificate}/key.pem";
          root = site;
          extraConfig = "gzip on; gzip_types application/json; gzip_min_length 1;";
        };
      };
    };

    testScript = ''
      import json

      machine.succeed(
          "install -d /srv/site && echo 'hello from the site' > /srv/site/hello.txt",
          "systemd-run --unit=site python3 -m http.server 8000 --bind 10.9.9.1 --directory /srv/site",
          # Keeps every connection open, for a program of the guest to hold one.
          "systemd-run --unit=hold python3 -c 'import socket, time; s = socket.create_server((\"10.9.9.1\", 9000)); c = [s.accept() for _ in range(1)]; time.sleep(120)'",
          "install -d -o alice /tmp/work/out",
          "printf '%s\\n' 'import base64, json, sys' 'flow = json.load(sys.stdin)'"
          " 'sent = [base64.b64decode(c[\"data\"]) for c in flow[\"chunks\"] if c[\"sent\"]]'"
          " 'print(flow[\"decrypted\"], sent[0][:14])' > /tmp/work/first.py",
      )
      machine.wait_for_unit("nginx.service")
      machine.wait_until_succeeds("curl -sf http://10.9.9.1:8000/hello.txt", timeout=30)
      start_driven()

      def run(script):
          return machine.succeed(lab(f"cd /tmp/work && vm-inspect --net --control driven -- sh -c {shlex.quote('{ ' + script + '; } 2>&1')} 2>&1"))

      out = run("; ".join([
          "guest-mark start",
          "guest-exec --shell 'nslookup site.test 10.9.9.1 > /dev/null; wget -q -O - http://site.test:8000/hello.txt'",
          "guest-exec --shell 'SSLKEYLOGFILE=/tmp/keys.log curl -sk --http2 --resolve tls.test:8443:10.9.9.1 https://tls.test:8443/secret.txt'",
          "guest-push ${posts} /tmp/posts.sh > /dev/null && guest-exec /bin/sh /tmp/posts.sh > /dev/null",
          "guest-push ${steering} /tmp/steering.sh > /dev/null && guest-exec /bin/sh /tmp/steering.sh > /dev/null",
          "guest-exec --job --shell 'sleep 30 | nc 10.9.9.1 9000' > /dev/null",
          "guest-wait --process nc --timeout 20 > /dev/null",
          "guest-mark done",
          "echo == owners; guest-net owners --from agent",
          "echo == summary; guest-net summary",
          "echo == flows; guest-net flows",
          "echo == dns; guest-net dns",
          "echo == tls before; guest-net tls",
          "echo == http before; guest-net http",
          "echo == keys; guest-net keys pull /tmp/keys.log && guest-net keys list",
          "echo == tls after; guest-net tls",
          "echo == http after; guest-net http",
          "echo == by host; guest-net flows --host site.test",
          "echo == by process; guest-net flows --process nc",
          "echo == by parent; guest-net flows --process 1 --children",
          "echo == parent alone; guest-net flows --process 1",
          "echo == http by host; guest-net http --host tls.test",
          "echo == dns by host; guest-net dns --host site.test",
          "echo == packets by process; guest-net packets --process nc --max 100",
          "echo == summary by process; guest-net summary --process nc",
          "echo == hello; guest-net http $(guest-net http | grep hello.txt | cut -d' ' -f1)",
          "echo == secret; guest-net http --save secret.txt $(guest-net http | grep secret.txt | cut -d' ' -f1)",
          "echo == json; guest-net http $(guest-net http | grep 'GET https://tls.test:8443/data.json' | cut -d' ' -f1)",
          "echo == posted; guest-net http $(guest-net http | grep 'POST https://tls.test:8443/data.json' | cut -d' ' -f1)",
          "echo == form; guest-net http $(guest-net http | grep 'POST http://site.test:8000/form' | cut -d' ' -f1)",
          "echo == kept; guest-net http --save posted $(guest-net http | grep 'POST https' | cut -d' ' -f1) && cat /tmp/work/out/posted.request",
          "echo == stream; guest-net stream $(guest-net flows | grep ':8000 ' | head -n 1 | cut -d' ' -f1)",
          "echo == window; guest-net flows --since done",
          "echo == packets; guest-net packets dns --max 4",
          "echo == export; guest-net export --decrypted all.pcapng",
          "echo == har; guest-net export --har all.har",
          "echo == decoded; guest-net decode $(guest-net flows | grep ':8443 ' | head -n 1 | cut -d' ' -f1) --decrypted --with /tmp/work/first.py",
          "echo == inside; guest-net stream $(guest-net flows | grep ':8443 ' | tail -n 1 | cut -d' ' -f1) --decrypted",
          "echo == conversations; guest-net tshark -q -z conv,tcp",
          "echo == captures; guest-net captures",
          "echo == elsewhere; VM_INSPECT_CAPTURE=/elsewhere/driven/$(basename $VM_INSPECT_CAPTURE) guest-net summary",
      ]))
      print(out)
      section = {}
      for part in out.split("== ")[1:]:
          name, _, said = part.partition("\n")
          section[name.strip()] = said

      with subtest("the names, the flows, the page and the marks of the capture are read back"):
          assert "site.test" in section["summary"] and "start" in section["summary"] and "done" in section["summary"], section["summary"]
          assert re.search(r"10\.9\.9\.50:\d+ -> 10\.9\.9\.1:8000  site\.test", section["flows"]), section["flows"]
          assert "A     site.test -> 10.9.9.1" in section["dns"], section["dns"]
          assert re.search(r"GET http://site\.test:8000/hello\.txt -> 200 OK", section["http before"]), section["http before"]
          assert "hello from the site" in section["hello"] and "Server: SimpleHTTP" in section["hello"], section["hello"]
          assert "-> the guest sent" in section["stream"] and "GET /hello.txt" in section["stream"], section["stream"]
          assert "<- the guest got" in section["stream"] and "hello from the site" in section["stream"], section["stream"]
          assert "site.test" not in section["window"], "a flow from before the mark was shown after it"
          assert section["packets"].count("DNS") >= 2, section["packets"]
          assert re.search(r"10\.9\.9\.50\s*<->\s*10\.9\.9\.1", section["conversations"]) or "10.9.9.1" in section["conversations"], section["conversations"]

      with subtest("TLS is named and stays closed without keys, and opens with those the guest's program wrote"):
          assert re.search(r"tls\.test\s+TLS 1\.3 .*h2.*encrypted, the capture has no keys", section["tls before"]), section["tls before"]
          assert "secret.txt" not in section["http before"], section["http before"]
          assert re.search(r"CLIENT_TRAFFIC_SECRET_0 3", section["keys"]) and "lines added" in section["keys"], section["keys"]
          assert re.search(r"tls\.test\s+TLS 1\.3 .*decrypted", section["tls after"]), section["tls after"]
          assert re.search(r"GET https://tls\.test:8443/secret\.txt -> 200", section["http after"]), section["http after"]
          assert machine.succeed("cat /tmp/work/out/secret.txt") == "the secret behind TLS"
          exported = machine.succeed("${tshark} -n -r /tmp/work/out/all.pcapng -Y http2.headers.path -T fields -e http2.headers.path")
          assert "/secret.txt" in exported, "the exported capture does not open without the keys beside it"

      with subtest("the requests of HTTP/1 and HTTP/2 go into a HAR file with their headers and bodies, undone of their encoding"):
          entries = json.loads(machine.succeed("cat /tmp/work/out/all.har"))["log"]["entries"]
          # The first of each, as a page asked for twice keeps the first in the listing too.
          by_url = {(entry["request"]["method"], entry["request"]["url"]): entry for entry in reversed(entries)}
          hello = by_url[("GET", "http://site.test:8000/hello.txt")]
          assert hello["request"]["httpVersion"] == "HTTP/1.1" and hello["response"]["content"]["text"] == "hello from the site\n", hello
          secret = by_url[("GET", "https://tls.test:8443/secret.txt")]
          assert secret["request"]["httpVersion"] == "h2" and secret["response"]["content"]["text"] == "the secret behind TLS", secret
          posted = by_url[("POST", "https://tls.test:8443/data.json")]
          assert json.loads(posted["request"]["postData"]["text"]) == {"user": "alice", "pin": 1234}, posted["request"]
          assert by_url[("GET", "https://tls.test:8443/data.json")]["response"]["content"]["text"].startswith('{"name": "site"'), entries
          assert by_url[("POST", "http://site.test:8000/form")]["request"]["postData"]["text"] == "name=alice&pin=1234", entries

      with subtest("a decoder of a program's own protocol reads a flow from inside TLS"):
          assert "True b'PRI * HTTP/2.0'" in section["decoded"], section["decoded"]

      with subtest("a flow followed inside TLS is that flow, though tshark numbers the streams of TLS apart from those of TCP"):
          # The last connection to tls.test is the JSON POST of posts.sh, whose own body and answer have to be there. The server's
          # settings of HTTP/2 may come before the client's first bytes in TLS 1.3, so the order is not asked for.
          inside = section["inside"]
          assert '{"user":"alice","pin":1234}' in inside and "405 Not Allowed" in inside and "-> the guest sent" in inside, inside

      with subtest("bodies read as meant: undone of their encoding, JSON laid out, and the requests' own with them"):
          assert "content-encoding: gzip" in section["json"] and '\n  "name": "site",' in section["json"], section["json"]
          assert "request body:" in section["posted"] and '"user": "alice",' in section["posted"] and "-> 405" in section["posted"], section["posted"]
          assert "request body:" in section["form"] and "name=alice&pin=1234" in section["form"], section["form"]
          assert '{"user":"alice","pin":1234}' in section["kept"], section["kept"]
          assert re.search(r"GET http://site\.test:8000/hello\.txt -> 200 OK in \d+ ms", section["http before"]), section["http before"]
          assert re.search(r"GET https://tls\.test:8443/secret\.txt -> 200 in \d+ ms", section["http after"]), section["http after"]

      with subtest("each connection is put to the program that held it, as the guest's own tools named it"):
          assert re.search(r"tcp 10\.9\.9\.50:\d+ -> 10\.9\.9\.1:9000 .*nc\[\d+\]", section["owners"]), section["owners"]
          assert re.search(r"10\.9\.9\.1:9000 .* nc\[\d+\]", section["flows"]), section["flows"]

      with subtest("--host and --process keep the flows of a host or a program, and --children those of the programs it started"):
          # Every server of this test is at 10.9.9.1, so a flow without a name of its own goes by site.test, the name looked up for it.
          assert "site.test" in section["by host"] and "tls.test" not in section["by host"] and ":8443" not in section["by host"], section["by host"]
          assert re.search(r"10\.9\.9\.1:9000 .* nc\[\d+\]", section["by process"]), section["by process"]
          assert ":8000" not in section["by process"] and ":8443" not in section["by process"], section["by process"]
          assert re.search(r"10\.9\.9\.1:9000 .* nc\[\d+\]", section["by parent"]), "nc descends from the guest's first process, through the agent and a shell"
          assert ":9000" not in section["parent alone"] and "whose program is not known are left out" in section["parent alone"], section["parent alone"]
          assert "GET https://tls.test:8443/secret.txt" in section["http by host"] and "site.test" not in section["http by host"], section["http by host"]
          assert "site.test -> 10.9.9.1" in section["dns by host"], section["dns by host"]
          assert ":9000" in section["packets by process"] or "9000" in section["packets by process"], section["packets by process"]
          assert "8443" not in section["packets by process"] and "8000" not in section["packets by process"], section["packets by process"]
          assert "chosen   nc" in section["summary by process"] and "flows    1 tcp, 0 udp" in section["summary by process"], section["summary by process"]

      with subtest("what the guest sent to steer a terminal is shown without it"):
          assert "\x1b" not in out, "a character a terminal acts on came through"
          assert "?[2Jcleared" in section["http before"], section["http before"]

      with subtest("a capture named by a path this side does not have is found under its own home, as in a lab inside another sandbox"):
          assert "site.test" in section["elsewhere"] and "no capture" not in section["elsewhere"], section["elsewhere"]

      with subtest("requests show as they are made"):
          out = run("; ".join([
              "guest-net watch --seconds 8 > /tmp/work/out/watched & sleep 2",
              "guest-exec --shell 'wget -q -O /dev/null http://site.test:8000/hello.txt'; wait",
              "cat /tmp/work/out/watched",
          ]))
          print(out)
          assert "GET http://site.test:8000/hello.txt" in out and "answer 200" in out, out
    '';
  }
)

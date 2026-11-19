# nix build --no-link -L .#tests.lab.tlsscan-libraries
# keys scan's search in the live memory of TLS clients of OpenSSL, GnuTLS, NSS, mbedTLS, Go and rustls, each in TLS 1.3 and 1.2, against what each wrote to its own key log.
{
  host,
}:

let
  inherit (host) pkgs;
  tlsscan = pkgs.callPackage ../_capture/tlsscan/tlsscan.nix { };

  goClient = pkgs.runCommand "go-tls-client" { nativeBuildInputs = [ pkgs.go ]; } ''
    export HOME=$TMPDIR GOCACHE=$TMPDIR/cache CGO_ENABLED=0
    cp ${./tlsscan_go_client.go} main.go
    go build -o $out/bin/go-tls-client main.go
  '';

  # rustls-ffi's own test client, a program on rustls through its C interface.
  rustlsClient = pkgs.stdenv.mkDerivation {
    name = "rustls-client";
    dontUnpack = true;
    buildInputs = [ pkgs.rustls-ffi ];
    buildPhase = ''
      tests=${pkgs.rustls-ffi.src}/librustls/tests
      $CC -O2 -I$tests $tests/client.c $tests/common.c -lrustls -o rustls-client
    '';
    installPhase = "install -D rustls-client $out/bin/rustls-client";
  };

  openssl = "${pkgs.openssl.bin}/bin/openssl";
  gnutls = "${pkgs.gnutls.bin}/bin/gnutls-cli";
  mbedtls = "${pkgs.mbedtls}/bin/ssl_client2";
  rustls = "${rustlsClient}/bin/rustls-client";
  keylog = {
    SSLKEYLOGFILE = "@LOG@";
  };
  # GnuTLS reads its own name for it.
  gnutlsKeylog = keylog // {
    GNUTLS_KEYLOGFILE = "@LOG@";
  };

  clients = {
    openssl-13 = {
      command = [
        openssl
        "s_client"
        "-connect"
        "127.0.0.1:@PORT@"
        "-keylogfile"
        "@LOG@"
        "-quiet"
        "-tls1_3"
      ];
      stdin = true;
    };
    openssl-12 = {
      command = [
        openssl
        "s_client"
        "-connect"
        "127.0.0.1:@PORT@"
        "-keylogfile"
        "@LOG@"
        "-quiet"
        "-tls1_2"
        "-cipher"
        "ECDHE-RSA-AES128-GCM-SHA256"
      ];
      stdin = true;
    };
    gnutls-13 = {
      command = [
        gnutls
        "--insecure"
        "-p"
        "@PORT@"
        "127.0.0.1"
        "--priority"
        "NORMAL:-VERS-ALL:+VERS-TLS1.3"
      ];
      env = gnutlsKeylog;
      stdin = true;
    };
    gnutls-12 = {
      command = [
        gnutls
        "--insecure"
        "-p"
        "@PORT@"
        "127.0.0.1"
        "--priority"
        "NORMAL:-VERS-ALL:+VERS-TLS1.2"
      ];
      env = gnutlsKeylog;
      stdin = true;
    };
    nss-13 = {
      command = [
        "${pkgs.nss.tools}/bin/tstclnt"
        "-d"
        "sql:nssdb"
        "-h"
        "127.0.0.1"
        "-p"
        "@PORT@"
        "-o"
        "-V"
        "tls1.3:tls1.3"
      ];
      env = keylog;
      stdin = true;
    };
    nss-12 = {
      command = [
        "${pkgs.nss.tools}/bin/tstclnt"
        "-d"
        "sql:nssdb"
        "-h"
        "127.0.0.1"
        "-p"
        "@PORT@"
        "-o"
        "-V"
        "tls1.2:tls1.2"
      ];
      env = keylog;
      stdin = true;
    };
    mbedtls-13 = {
      command = [
        mbedtls
        "server_addr=127.0.0.1"
        "server_port=@PORT@"
        "auth_mode=none"
        "force_version=tls13"
        "nss_keylog=1"
        "nss_keylog_file=@LOG@"
      ];
    };
    mbedtls-12 = {
      command = [
        mbedtls
        "server_addr=127.0.0.1"
        "server_port=@PORT@"
        "auth_mode=none"
        "force_version=tls12"
        "nss_keylog=1"
        "nss_keylog_file=@LOG@"
      ];
    };
    go-13 = {
      command = [
        "${goClient}/bin/go-tls-client"
        "127.0.0.1:@PORT@"
        "1.3"
      ];
      env = keylog;
    };
    go-12 = {
      command = [
        "${goClient}/bin/go-tls-client"
        "127.0.0.1:@PORT@"
        "1.2"
      ];
      env = keylog;
    };
    rustls-13 = {
      command = [
        rustls
        "127.0.0.1"
        "@PORT@"
        "/"
        "1"
      ];
      env = keylog // {
        NO_CHECK_CERTIFICATE = "1";
        RUSTLS_CIPHERSUITE = "TLS13_AES_128_GCM_SHA256";
      };
    };
    rustls-12 = {
      command = [
        rustls
        "127.0.0.1"
        "@PORT@"
        "/"
        "1"
      ];
      env = keylog // {
        NO_CHECK_CERTIFICATE = "1";
        RUSTLS_CIPHERSUITE = "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256";
      };
    };
  };

  # What decrypts the traffic: both traffic secrets of TLS 1.3, the master secret of TLS 1.2.
  expected = builtins.mapAttrs (
    name: _:
    if pkgs.lib.hasSuffix "-13" name then
      [
        "CLIENT_TRAFFIC_SECRET_0"
        "SERVER_TRAFFIC_SECRET_0"
      ]
    else
      [ "CLIENT_RANDOM" ]
  ) clients;
in
pkgs.runCommand "guest-net-tlsscan-libraries"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.openssl
    ];
  }
  ''
    cd "$(mktemp -d)"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 1 -subj /CN=localhost \
      -addext subjectAltName=DNS:localhost,IP:127.0.0.1 2>/dev/null
    mkdir nssdb && ${pkgs.nss.tools}/bin/certutil -N -d sql:nssdb --empty-password
    python3 -I -B ${./tlsscan_libraries.py} ${../_capture} ${tlsscan}/lib/libtlsscan.so \
      ${pkgs.writeText "clients.json" (builtins.toJSON clients)} ${pkgs.writeText "expected.json" (builtins.toJSON expected)}
    touch $out
  ''

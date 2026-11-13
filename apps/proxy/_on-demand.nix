{ lib, pkgs, systemd }:

rec {
  # The socket unit holds the public address, so the proxy behind it listens on a second loopback address, same port.
  backend = "127.0.0.2";

  listenAssertion = option: listen: {
    assertion = !lib.elem listen [ "0.0.0.0" "::" backend ];
    message = "${option} is ${listen}, which covers ${backend}, where the proxy behind the socket listens.";
  };

  # Holds the start back until the proxy accepts, or the relay would forward the first connection into a closed port.
  ready = pkgs.writeShellScript "proxy-ready" ''
    for ((attempt = 0; attempt < 100; attempt++)); do
      open=1
      for port in "$@"; do
        (exec 3<>"/dev/tcp/${backend}/$port") 2>/dev/null || open=0
      done
      [ "$open" = 1 ] && exit 0
      ${lib.getExe' pkgs.coreutils "sleep"} 0.1
    done
    exit 1
  '';

  front =
    {
      name,
      core,
      description,
      listen,
      port,
      idleTimeout,
      socketConfig ? { },
    }:
    {
      sockets.${name} = {
        description = "Socket of the ${description}";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "${listen}:${toString port}" ];
        inherit socketConfig;
      };

      services.${name} = {
        description = "Relay to the ${description}";
        after = [ core ];
        # Unlike wants, this brings the proxy back when something stops it or its secret file shows up late.
        upholds = [ core ];
        serviceConfig = {
          ExecStart = "${systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=${idleTimeout} ${backend}:${toString port}";
          NoNewPrivileges = true;
        };
      };
    };

  core = ports: {
    unitConfig.StopWhenUnneeded = true;
    serviceConfig.ExecStartPost = "${ready} ${lib.concatMapStringsSep " " toString ports}";
  };
}

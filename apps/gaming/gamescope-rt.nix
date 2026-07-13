{ config, lib, pkgs, ... }:

/*
Grants gamescope realtime scheduling without a user-wide rlimit and
without capSysNice's setcap wrapper, which aborts inside Steam's
pressure-vessel container (no_new_privs blocks ambient caps,
nixpkgs#351516).

A socket-activated helper holds CAP_SYS_NICE and applies SCHED_RR to a
requested pid only after verifying its /proc/<pid>/exe resolves into
the gamescope store path. The capability never exists outside the
daemon, and rlimits stay untouched. Launch games through the
gamescope-rt wrapper instead of plain gamescope.
*/

let
  cfg = config.nyx.apps.gaming;
  user = config.nyx.flake.user;

  socketPath = "/run/gamescope-rt.sock";
  gamescopeStore = toString pkgs.gamescope;

  daemon = pkgs.writeText "gamescope-rtd.py" ''
    import os
    import socket
    import struct

    GAMESCOPE_PREFIX = "${gamescopeStore}/"
    RT_PRIO = 1


    def exe_allowed(pid):
        try:
            return os.readlink(f"/proc/{pid}/exe").startswith(GAMESCOPE_PREFIX)
        except OSError:
            return False


    def proc_uid(pid):
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("Uid:"):
                    return int(line.split()[1])
        raise ValueError("no Uid line")


    def set_all_threads(pid, policy, prio):
        for tid in os.listdir(f"/proc/{pid}/task"):
            try:
                os.sched_setscheduler(int(tid), policy, os.sched_param(prio))
            except (ProcessLookupError, PermissionError):
                pass


    srv = socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)
    while True:
        conn, _ = srv.accept()
        try:
            creds = conn.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            _, peer_uid, _ = struct.unpack("3i", creds)
            target = int(conn.recv(32).strip())

            # pidfd pins the pid against reuse while we verify and apply
            pidfd = os.pidfd_open(target)
            try:
                if proc_uid(target) != peer_uid or not exe_allowed(target):
                    conn.sendall(b"denied\n")
                    continue

                # RESET_ON_FORK keeps the game process gamescope spawns
                # from inheriting realtime class
                set_all_threads(
                    target, os.SCHED_RR | os.SCHED_RESET_ON_FORK, RT_PRIO)

                # re-verify to close the pid-reuse window between the
                # exe check and the sched calls
                if not exe_allowed(target):
                    set_all_threads(target, os.SCHED_OTHER, 0)
                    conn.sendall(b"revoked\n")
                else:
                    conn.sendall(b"ok\n")
            finally:
                os.close(pidfd)
        except Exception as exc:
            try:
                conn.sendall(f"err {exc}\n".encode())
            except OSError:
                pass
        finally:
            conn.close()
  '';

  notify = pkgs.writeShellScript "gamescope-rt-notify" ''
    sleep 0.5
    printf '%s' "$1" | ${pkgs.python3}/bin/python3 -c '
    import socket, sys
    s = socket.socket(socket.AF_UNIX)
    s.connect("${socketPath}")
    s.sendall(sys.stdin.read().encode() + b"\n")
    s.recv(16)
    '
  '';

  /*
  Steam SIGKILLs the session when it reaps forks it did not expect in
  the launch chain, so the wrapper must not fork: the notifier runs as
  a transient user unit outside Steam's process tree, and exec keeps
  gamescope as Steam's direct child under the shell's own pid.

  Steam's LD_PRELOAD overlay must not load into gamescope itself: it
  degrades the compositor over time (gamescope#163). Strip it for
  gamescope, restore it for the game after the -- separator.
  */
  client = pkgs.writeShellScriptBin "gamescope-rt" ''
    orgPreload="$LD_PRELOAD"
    orgLibPath="$LD_LIBRARY_PATH"

    gsArgs=()
    while [ $# -gt 0 ]; do
      if [ "$1" = "--" ]; then shift; break; fi
      gsArgs+=("$1"); shift
    done

    ${pkgs.systemd}/bin/systemd-run --user --quiet --collect ${notify} "$$" 2>/dev/null || true

    if [ $# -eq 0 ]; then
      LD_PRELOAD= LD_LIBRARY_PATH= exec ${lib.getExe pkgs.gamescope} "''${gsArgs[@]}"
    fi
    LD_PRELOAD= LD_LIBRARY_PATH= exec ${lib.getExe pkgs.gamescope} "''${gsArgs[@]}" -- \
      ${pkgs.coreutils}/bin/env LD_PRELOAD="$orgPreload" LD_LIBRARY_PATH="$orgLibPath" "$@"
  '';
in
{
  config = lib.mkIf (cfg.enable && cfg.steam.enable) {
    environment.systemPackages = [ client ];
    programs.steam.extraPackages = [ client ];

    systemd.sockets.gamescope-rt = {
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = socketPath;
        SocketMode = "0600";
        SocketUser = user;
      };
    };

    systemd.services.gamescope-rt = {
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${daemon}";
        User = user;
        AmbientCapabilities = [ "CAP_SYS_NICE" ];
        CapabilityBoundingSet = [ "CAP_SYS_NICE" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}

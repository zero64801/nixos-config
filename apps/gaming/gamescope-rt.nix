{ config, lib, pkgs, ... }:

# A socket-activated CAP_SYS_NICE helper replaces capSysNice, whose setcap wrapper aborts inside pressure-vessel because no_new_privs blocks ambient caps (nixpkgs#351516).

let
  cfg = config.my.apps.gaming;
  user = config.my.flake.user;

  socketPath = "/run/gamescope-rt.sock";
  gamescopeStore = toString pkgs.gamescope;
  flatpakGamescopeDeploy = "/var/lib/flatpak/runtime/org.freedesktop.Platform.VulkanLayer.gamescope/";

  daemon = pkgs.writeText "gamescope-rtd.py" ''
    import glob
    import os
    import select
    import socket
    import struct
    import threading
    import time

    HOST_PREFIX = "${gamescopeStore}/"
    # The extension's bin/gamescope is a wrapper script that execs the gamescope-brokey ELF, hence the glob.
    FLATPAK_GLOB = "${flatpakGamescopeDeploy}*/*/active/files/bin/gamescope*"
    RT_PRIO = 1
    EXEC_WAIT_S = 5.0


    def flatpak_inodes():
        inodes = set()
        for path in glob.glob(FLATPAK_GLOB):
            try:
                st = os.stat(path)
            except OSError:
                continue
            inodes.add((st.st_dev, st.st_ino))
        return inodes


    def exe_allowed(pid):
        # readlink renders sandbox paths for other mount namespaces, so flatpak gamescope is matched by the inode the opened magic link reaches.
        try:
            fd = os.open(f"/proc/{pid}/exe", os.O_PATH)
        except OSError:
            return False
        try:
            st = os.fstat(fd)
        finally:
            os.close(fd)
        if (st.st_dev, st.st_ino) in flatpak_inodes():
            return True
        try:
            return os.readlink(f"/proc/{pid}/exe").startswith(HOST_PREFIX)
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


    def client_gone(conn):
        readable, _, _ = select.select([conn], [], [], 0)
        return bool(readable)


    def handle(conn):
        try:
            creds = conn.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            pid, peer_uid, _ = struct.unpack("3i", creds)

            pidfd = os.pidfd_open(pid)
            try:
                deadline = time.monotonic() + EXEC_WAIT_S
                while not exe_allowed(pid):
                    if client_gone(conn) or time.monotonic() > deadline:
                        return
                    time.sleep(0.05)

                if proc_uid(pid) != peer_uid:
                    return

                set_all_threads(
                    pid, os.SCHED_RR | os.SCHED_RESET_ON_FORK, RT_PRIO)

                # Re-verify to close the pid reuse window between the exe check and the sched calls.
                if not exe_allowed(pid):
                    set_all_threads(pid, os.SCHED_OTHER, 0)
            finally:
                os.close(pidfd)
        except Exception:
            pass
        finally:
            conn.close()


    srv = socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()
  '';

  # Steam's LD_PRELOAD overlay degrades gamescope over time (gamescope#163), so it is stripped for gamescope and restored for the game after the -- separator.
  # Under flatpak the SLR sub-sandbox resets DISPLAY to the host X server, so stage2 runs as gamescope's child and splices env DISPLAY=:N after the SLR entry point's --.
  mkClient = { python, gamescope, envBin }: ''
    #!${python}
    import os
    import socket
    import sys

    SOCKET = "${socketPath}"
    GAMESCOPE = "${gamescope}"
    ENV_BIN = "${envBin}"


    def slr_injection_point(args):
        for i, arg in enumerate(args):
            if "entry-point" in arg or "SteamLinuxRuntime" in arg:
                for j in range(i + 1, len(args)):
                    if args[j] == "--":
                        return j + 1
                return None
        return None


    if sys.argv[1:2] == ["--stage2"]:
        rest = sys.argv[2:]
        display = os.environ.get("DISPLAY", "")
        pos = slr_injection_point(rest)
        if pos is not None and display:
            rest[pos:pos] = ["env", "DISPLAY=" + display]
        os.execvp(rest[0], rest)

    args = sys.argv[1:]
    if "--" in args:
        split = args.index("--")
        gs_args, game = args[:split], args[split + 1:]
    else:
        gs_args, game = args, []
    if game:
        game = [sys.argv[0], "--stage2", *game]

    # The inheritable fd survives the exec so its close tells the daemon the process died.
    try:
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(2)
        sock.connect(SOCKET)
        sock.setblocking(True)
        sock.set_inheritable(True)
    except OSError:
        pass

    env = dict(os.environ)
    preload = env.pop("LD_PRELOAD", "")
    lib_path = env.pop("LD_LIBRARY_PATH", "")
    env["LD_PRELOAD"] = ""
    env["LD_LIBRARY_PATH"] = ""

    argv = [GAMESCOPE, *gs_args]
    if game:
        argv += ["--", ENV_BIN,
                 f"LD_PRELOAD={preload}",
                 f"LD_LIBRARY_PATH={lib_path}",
                 *game]
    os.execvpe(GAMESCOPE, argv, env)
  '';

  client = pkgs.writeScriptBin "gamescope-rt" (mkClient {
    python = "${pkgs.python3}/bin/python3";
    gamescope = lib.getExe pkgs.gamescope;
    envBin = "${pkgs.coreutils}/bin/env";
  });

  sandboxClient = pkgs.writeText "gamescope-rt-sandbox" (mkClient {
    python = "/usr/bin/python3";
    gamescope = "/usr/lib/extensions/vulkan/gamescope/bin/gamescope";
    envBin = "/usr/bin/env";
  });
in
{
  options.my.apps.gaming.gamescopeRt = {
    socketPath = lib.mkOption {
      type = lib.types.str;
      default = socketPath;
      readOnly = true;
      internal = true;
      description = "Path of the gamescope-rt daemon socket.";
    };

    sandboxClient = lib.mkOption {
      type = lib.types.path;
      default = sandboxClient;
      readOnly = true;
      internal = true;
      description = "gamescope-rt client script for the Steam flatpak sandbox.";
    };
  };

  # The daemon gates on gaming alone because the Steam flatpak needs it with native Steam disabled.
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ client ];
    programs.steam.extraPackages = lib.mkIf cfg.steam.enable [ client ];

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

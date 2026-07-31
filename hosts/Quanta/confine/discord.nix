{ config, inputs, lib, pkgs, ... }:

let
  proxy = config.nyx.apps.vlessProxy;
  proxied = proxy.enable && proxy.discordWrapper.enable;

  nixcordPkgs = inputs.nixcord.packages.${pkgs.stdenv.hostPlatform.system};

  # nixcord ships its own Discord, ahead of the one in nixpkgs. Reproduces the
  # module's package default, which is what this replaces.
  discord = pkgs.callPackage "${inputs.nixcord}/pkgs/discord" {
    openasar = nixcordPkgs.openasar;
  };
in
# Both launchers run this one build: discord-proxy execs bin/Discord out of the
# profile, which is the confined shim.
lib.mkIf config.nyx.apps.discord.enable {
  nyx.confine.apps.discord = {
    package = discord;
    appId = "com.discordapp.Discord";
    # nixcord installs the package, and it overrides to inject Vencord.
    install = false;

    profile = [
      "gui"
      "gpu"
      "audio"
      "tray"
      "chromium"
    ];

    /*
    Isolated keeps Discord off host loopback, where the llama.cpp servers, the
    samba share and the libvirt sockets live. The SOCKS port is punched back
    through for the proxy launcher, which connects to 127.0.0.1 on the host.
    */
    network = "isolated";
    networkPorts.toHost = lib.optional proxied proxy.socks.port;

    # The bundled keybind module segfaults the renderer in a loop without an X
    # display. The UI stays on Wayland, X serves only that module.
    x11 = "host";

    # TTS needs the host daemon reachable: without it libspeechd autospawns,
    # the failing spawn hits Chromium's descriptor guard and the client dies.
    # The service below keeps the daemon up, so the socket is always there.
    env.NIXOS_SPEECH = "True";

    binds.ro = [ "xdg-run/speech-dispatcher" ];

    binds.rw = [
      # Real paths: nixcord writes settings here on switch, the impermanence
      # module persists them, and both launchers share one account.
      ".config/discord"
      ".config/Vencord"
    ];
  };

  # Confined clients cannot autospawn a useful daemon, they would each get a
  # private one behind their own sandbox walls.
  systemd.user.services.speech-dispatcher = {
    description = "Speech Dispatcher TTS daemon";
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.speechd}/bin/speech-dispatcher --run-single";
      # The daemon exits on its idle timeout by design.
      Restart = "always";
      RestartSec = 2;
    };
  };

  # The override forwards through the wrapper and re-confines, so the Vencord
  # injection cannot hand back an unsandboxed build.
  hm.programs.nixcord.discord.package = config.nyx.confine.packages.discord;
}

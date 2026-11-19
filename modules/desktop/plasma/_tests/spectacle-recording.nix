# nix build --no-link -L .#tests.plasma.spectacle-recording
{
  host,
}:

let
  inherit (host) pkgs;
in
host.boot {
  name = "spectacle-recording";

  machines.machine = {
    users.users.alice.uid = 1000;

    services.getty.autologinUser = "alice";
    services.pipewire.enable = true;
    hardware.graphics.enable = true;

    programs.bash.loginShellInit = ''
      if [ "$(tty)" = /dev/tty1 ]; then
        exec kwin_wayland --drm --no-lockscreen --no-global-shortcuts --no-kactivities > /tmp/kwin.log 2>&1
      fi
    '';

    environment.systemPackages = [
      # With false it is Spectacle as it comes, which this test fails on.
      (pkgs.callPackage ../_spectacle.nix { recording = true; })
      pkgs.kdePackages.kwin
      pkgs.ffmpeg-headless
      pkgs.foot
    ];

    virtualisation = {
      memorySize = 4096;
      cores = 4;
      # The default display has no driver KWin can render with.
      qemu.options = [ "-vga none -device virtio-gpu-pci" ];
    };
  };

  testScript = ''
    import datetime

    minute = datetime.timedelta(seconds=60)
    session = "XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus WAYLAND_DISPLAY=wayland-0"
    spectacle = "spectacle --background --nonotify --record"
    runs = 0


    def start(unit, command):
        machine.succeed(f"systemd-run --unit={unit} su - alice -c 'export {session}; exec {command}'")


    def record(settings, mode="screen"):
        """Records the screen, or all of it as a region, for a few seconds and returns the saved file."""
        global runs
        runs += 1
        machine.succeed(
            "rm -rf /home/alice/Videos",
            f"printf '[VideoSave]\\n{settings}' > /home/alice/.config/spectaclerc",
            "chown alice /home/alice/.config/spectaclerc",
        )
        start(f"spectacle-{runs}", f"{spectacle} {mode}")

        # Spectacle has KWin ask which screen with a pick, and Return picks the window under the pointer.
        # For a region it shows its own picker, where Return with nothing selected takes everything.
        def picked(_):
            machine.send_key("ret")
            return machine.execute("find /tmp -name 'Screencast_*' | grep -q .")[0] == 0

        retry(picked, timeout=minute)
        machine.sleep(datetime.timedelta(seconds=5))
        # A second launch ends a running recording.
        machine.succeed(f"su - alice -c 'export {session}; {spectacle} {mode}'")
        machine.wait_until_fails(f"systemctl is-active spectacle-{runs}", timeout=minute)
        return machine.succeed("find /home/alice/Videos/Screencasts -type f -size +0").strip()


    def crf(file):
        """The quality x264 was run with, which it writes into the stream."""
        return machine.succeed(f"grep -a -o -m1 'crf=[0-9.]*' {file} | head -n1").strip()


    def size(file):
        return machine.succeed(f"ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 {file}").strip()


    def intervals(file):
        """How many frames follow the one before them by each whole number of milliseconds."""
        counts = machine.succeed(
            f"ffprobe -v error -select_streams v -show_entries packet=pts_time -of csv=p=0 {file}"
            " | awk 'NR > 1 { n[int(($1 - last) * 1000 + 0.5)]++ } { last = $1 } END { for (ms in n) print ms, n[ms] }'"
        )
        return {int(ms): int(n) for ms, n in (line.split() for line in counts.splitlines())}


    machine.wait_for_file("/run/user/1000/wayland-0")
    machine.succeed("install -d -o alice /home/alice/.config")
    # Only a screen that changes gives the recorder frames.
    start("ticker", "foot --fullscreen sh -c \"while :; do date +%N; done\"")
    machine.wait_until_succeeds("pgrep -x foot")

    with subtest("the format and the quality in spectaclerc reach the encoder"):
        file = record("preferredVideoFormat=2\\nvideoQuality=72\\n")
        assert file.endswith(".mp4"), f"not recorded as MP4: {file}"
        assert crf(file) == "crf=20.1", f"quality 72 did not reach the encoder: {crf(file)} in {file}"

    with subtest("a frame that follows the last by a 60th of a second is kept"):
        spacing = intervals(file)
        print(f"frame spacing in ms: {sorted(spacing.items())}")
        assert spacing.get(16, 0) > 0, f"no two frames are 16 ms apart, so every third is dropped: {sorted(spacing.items())}"

    with subtest("without a quality the encoder keeps its default"):
        file = record("preferredVideoFormat=2\\n")
        assert crf(file) == "crf=23.0", f"the default changed: {crf(file)} in {file}"

    with subtest("a region is recorded enlarged by the factor in spectaclerc"):
        width, height = (int(n) for n in size(file).split(","))
        plain = record("preferredVideoFormat=2\\n", "region")
        assert size(plain) == f"{width},{height}", f"a region is no longer recorded at its own size: {size(plain)}"
        doubled = record("preferredVideoFormat=2\\nvideoRegionScale=2\\n", "region")
        assert size(doubled) == f"{2 * width},{2 * height}", f"the region was not doubled from {width},{height}: {size(doubled)}"
  '';
}

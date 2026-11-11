# confine

Bubblewrap sandboxes for NixOS packages, built to match Flatpak's sandbox and go further where Nix makes it possible.
Each app runs from its normal Nix package, with a launcher that sets up the sandbox, a filtered D-Bus proxy, portals and, when asked for, its own network namespace.
The launcher is a small Rust program that reads the app's settings from JSON written at build time, so starting an app runs no shell.

## Use

Import the module, from this flake's `nixosModules.default` or by path, and declare apps:

```nix
confine.apps.discord = {
  package = pkgs.discord;
  appId = "com.discordapp.Discord";
  profile = [ "gui" "gpu" "chromium" ];
  pulse = true;
  network = "isolated";
  binds.rw = [ ".config/discord" ];
};
```

The wrapped package replaces the original in `environment.systemPackages`, desktop entries, D-Bus services and systemd units included, so nothing starts the app unconfined.
`confine.packages.<name>` holds the wrapped build for other modules, such as Home Manager program options.
`confine.persistentHomeDirectories` lists the private homes to keep on an impermanent system.
`confine.lib.wrap` builds a sandbox outside `confine.apps`, and `confine.lib.seccomp` builds a filter for plain `bwrap --seccomp`.

## Permissions

Everything is closed unless an app or one of its profiles opens it.

| Setting | Default | Meaning |
|---|---|---|
| `profile` | `[ ]` | Presets merged under the app's own settings: `gui`, `gpu`, `audio`, `alsa`, `compute`, `tray`, `mpris`, `a11y`, `printing`, `chromium`, `steam`. |
| `network` | `"none"` | `"isolated"` gives the app its own network through pasta, without access to services on the host's loopback. `"host"` shares the host's network. |
| `networkPorts.toHost`, `.fromHost` | `[ ]` | Ports forwarded between the host's loopback and an isolated app. A `fromHost` port listens on `127.0.0.1` unless it names an address, as in `"0.0.0.0/8000"`. The first running instance of an app holds its `fromHost` ports, and a later one starts without them. |
| `networkSetups` | `{ }` | Named programs run inside the isolated network before the app, such as a VPN tunnel, chosen with `CONFINE_NETWORK_SETUP`. |
| `wayland` | `false` | Wayland access, through a security context so the compositor withholds screen capture, fake input, window management and background clipboard reads. |
| `x11` | `"none"` | `"host"` shares the host's X server. `"isolated"` gives the app its own X server through xwayland-satellite. |
| `pipewire`, `pulse` | `false` | Audio. `pulse` plays and records, and is all a browser or Electron app needs, since cameras and screen streams reach those through the portal. `pipewire` adds PipeWire's client socket, never the manager socket. That socket also carries video, and PipeWire restricts the app on it only when `portals` is set, which is how it tells a sandboxed app. |
| `gpu`, `sysfs` | `false` | GPU nodes and drivers, and the parts of `/sys` that graphics and input libraries read. |
| `devices` | `[ ]` | Device nodes or patterns to bind. |
| `securityKeys` | `false` | Whether `devices` may include FIDO and other security keys, which udev tags and which are otherwise left out. |
| `portals` | `false` | xdg-desktop-portal access, with the app identified by `appId` as a Flatpak app would be. |
| `a11y` | `false` | The accessibility bus, filtered as Flatpak filters it. |
| `home` | `"private"` | `"private"` keeps a home under `~/.local/share/confine/<appId>`. `"ephemeral"` starts empty every time. `"host"` shares the real home. |
| `hostAccounts` | `false` | Shows the host's passwd and group instead of ones listing only the user, as Flatpak generates them. |
| `binds.ro`, `binds.rw` | `[ ]` | Paths relative to the home, absolute paths, `./` paths relative to the folder the app starts in, `xdg-run/` paths, Flatpak's `xdg-download` style names, and glob patterns. |
| `workdir` | `null` | `"ro"` or `"rw"` shares the folder the app starts in, refusing the home itself or anything above it. |
| `gitGuard.enable`, `.depth` | `false`, `4` | Keeps hooks, config and commondir of every repository in a writable shared folder read only, with `.git` pinned in place, and reports repositories that gained any while the app ran. |
| `dbus.session.talk`, `.own`, `.call`, `.broadcast` | `[ ]` | Session bus rules for xdg-dbus-proxy. The app may always own its `appId` names. |
| `dbus.system.talk`, `.call` | `[ ]` | System bus rules. |
| `env`, `envPassthrough` | `{ }`, `[ ]` | Variables to set, and host variables to copy, into an otherwise cleared environment. |
| `seccomp.userns`, `.nesting`, `.devel`, `.multiarch`, `.bluetooth`, `.can`, `.ioUring` | `false` | Openings in the seccomp filter, Flatpak's plus io_uring. `userns` allows the user namespaces and chroot a browser builds its own sandbox from, with mounting still closed. A namespace guard then keeps the app from administering a network it creates: netlink sockets are refused outside the sandbox's own network, and raw sockets, the socket ioctls and options that change a network and writes to `/proc/sys` are refused everywhere. It does not combine with `multiarch` or `ioUring`, which make sockets no filter sees. `nesting` opens mounting too, for a bubblewrap inside the sandbox, as Steam's runtime is. Netfilter stays closed in both. |
| `linger` | `true` | Whether the sandbox runs on after its main process ended, see Lifetime. |
| `scope`, `resources` | `true`, `{ }` | A systemd scope per running app, with optional limits in systemd-run's spelling: `MemoryMax`, `MemoryHigh`, `MemorySwapMax`, `MemoryLow` and `MemoryMin` as sizes like `4G` or `infinity`, `CPUWeight`, `StartupCPUWeight`, `IOWeight`, `StartupIOWeight` and `TasksMax` as numbers, `CPUQuota` as a percentage. An app with limits refuses to start where it cannot get its scope, such as inside another sandbox. |
| `waylandAppId`, `binaries`, `binPrefix`, `keepDesktopNames`, `symlinks`, `runtimeDir`, `extraPastaArgs`, `extraBwrapArgs` | | Finer control, described in `_lib/wrap.nix`. |

## Compositors

A Wayland app starts only once the compositor has given it a security context, which is what makes the compositor withhold its privileged protocols.
KWin, Sway, Hyprland, niri, COSMIC, labwc and river have security contexts.
GNOME's Mutter and Weston have none, and offer ordinary clients no screen capture, fake input or clipboard control to begin with, so apps there set `waylandSecurityContext = false`.
A compositor that offers those to every client and has no security contexts, as Wayfire does, leaves `waylandProxy = true` as the only way to keep them from an app, at the cost of GPU buffer sharing and input methods.

## Commands

`confine list` shows the installed apps and `confine info APP` shows what one may reach.
`confine ps` lists running sandboxes, `confine kill` stops one with everything in it, and `confine run --command=sh APP` starts a command inside an app's sandbox.
`confine enter INSTANCE` joins a running sandbox, without privileges and under the same seccomp filter, which `flatpak enter` does not apply.
`confine-import APP_ID` turns a Flathub app's permissions into a starting `confine.apps` entry.

## Lifetime

A sandbox runs until the last process in it ends, as Flatpak's does, so an app whose command starts the real program in the background and exits keeps running.
The launch returns with the main process's exit status as soon as that process ends, as `flatpak run` does, while the D-Bus proxy, pasta, the scope and the git audit stay with the sandbox until its end.
When nothing outlives the main process, the launch returns only after that cleanup, so a script that runs a confined tool finds the git audit done.
`linger = false` ends the sandbox with its main process instead.
That suits tools run in a terminal, where a process left behind still holds the terminal and could read what is typed after the tool returned.
Stopping or killing the launcher ends its sandbox, however it is done.

Only the app and what it starts hold the caller's stdin, stdout and stderr, so whoever reads a launch's output waits for those and never for confine's own helpers.
Whatever else the caller left open is closed and does not reach the sandbox.
A launch that is a terminal's foreground job stays in that job, which keeps Ctrl+C and job control working.
Ctrl+C is the app's to answer, and a sandbox whose app handles it runs on.
Anywhere else the sandbox gets a process group of its own, as Flatpak's does, so it cannot signal its caller.
The process that cleans up and runs the git audit sits outside the sandbox's group in both cases, out of reach of a `kill` from inside.
With `scope = false` the sandbox stays in its caller's systemd unit, so a service that started it ends when the launch returns and takes what lingers along, as it would for the app without confine.

## Startup

The launcher starts the D-Bus proxy and pasta at once and builds the bwrap command line while systemd moves it into the app's scope, then moves those helpers in after it.
Measured on a desktop, an app starts in about 8 ms, or 15 ms with its scope, where `flatpak run` of a similar app took about 70 ms.
Most of the scope's share is the kernel moving the launcher between cgroups, which waits for an RCU grace period.
Mounting cgroup2 with `favordynmods` removes that wait, at a small cost to every fork and exit on the system.

## Compared with Flatpak

| Flatpak | confine |
|---|---|
| `--share=network` | `network = "isolated"`, with the host's loopback closed, or `"host"` |
| `--socket=wayland` | `wayland = true`, in a security context |
| `--socket=x11`, `fallback-x11` | `x11 = "host"`, or `"isolated"` for an X server of its own |
| `--socket=pulseaudio`, `--device=dri` | `pulse = true`, `gpu = true` |
| `--device=all`, `input`, `kvm` | named nodes in `devices` |
| `--filesystem=xdg-download:ro` | `binds.ro = [ "xdg-download" ]` |
| `--talk-name`, `--own-name`, `--system-talk-name` | `dbus.session.talk`, `dbus.session.own`, `dbus.system.talk` |
| `--allow=devel`, `multiarch`, `bluetooth`, `canbus` | `seccomp.devel`, `multiarch`, `bluetooth`, `can` |
| file forwarding with `@@` | automatic for apps with `portals = true` |
| `flatpak ps`, `kill`, `enter`, `info`, `run --command` | `confine ps`, `kill`, `enter`, `info`, `run --command` |
| `flatpak override` | the Nix configuration, there are no runtime overrides a process could loosen |

Beyond Flatpak, confine isolates the network per app, can give an app its own X server, blocks io_uring unless asked, lets a browser keep its namespace sandbox without the network administration that comes with it, keeps security keys out of device patterns, guards git repositories in shared folders, runs its D-Bus proxy in a sandbox of its own, and runs every app in a scope that can be limited.
Unlike Flatpak, every sandbox sees the whole read only Nix store and the host's `/etc`, minus credentials, since the store is the runtime here.

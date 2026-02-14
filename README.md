# nixos-config

My NixOS configuration following the [Synaptic Standard](https://github.com/SynapticStandard/synaptic-standard).

## Structure

```
nixos/
├── apps/       Per-app modules, each gated by nyx.apps.<name>.enable
├── core/       Always-on system fundamentals (boot, audio, networking, etc.)
├── modules/    Feature modules with nyx.* options (impermanence, stylix, etc.)
├── hosts/      Per-host configuration (hardware, user, host-specific settings)
├── lib/        Helper functions (recursivelyImport)
├── pkgs/       Overlays, custom packages, and utility functions
├── flake.nix   Flake entry point
└── hosts.nix   Host builder (auto-discovers hosts/ subdirectories)
```

## Key Concepts

- **`nyx.*` namespace** — All custom options live under `nyx` for discoverability
- **`nyx.desktop.enable`** — Controls workstation vs headless mode
- **`nyx.apps.*`** — Each app has an explicit enable toggle
- **`nyx.persistence`** — Unified system + home persistence (used with impermanence)
- **`hm.*`** — Alias for `home-manager.users.<primary user>` via `mkAliasOptionModule`
- **`pkgs.util.importFlake`** — Wrapper for `flake-compat` to load sub-flake inputs

## Host: Quanta

Desktop workstation with KDE Plasma 6, AMD graphics, impermanence (btrfs rollback), and YubiKey authentication.

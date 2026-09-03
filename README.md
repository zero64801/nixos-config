# nixos-config

My NixOS configuration following the [Synaptic Standard](https://github.com/SynapticStandard/synaptic-standard).

## Structure

```
nixos/
├── apps/       Per-app modules, each gated by my.apps.<name>.enable
├── core/       Always-on system fundamentals (boot, audio, networking, etc.)
├── modules/    Feature modules with my.* options (impermanence, stylix, etc.)
├── hosts/      Per-host configuration (hardware, user, host-specific settings)
├── lib/        Helper functions (recursivelyImport)
├── pkgs/       Overlays, custom packages, and utility functions
├── flake.nix   Flake entry point
└── hosts.nix   Host builder (auto-discovers hosts/ subdirectories)
```

## Key Concepts

- **`my.*` namespace** — All custom options live under `my` for discoverability
- **`my.desktop.enable`** — Controls workstation vs headless mode
- **`my.apps.*`** — Each app has an explicit enable toggle
- **`my.persistence`** — Unified system + home persistence (used with impermanence)
- **`hm.*`** — Alias for `home-manager.users.<primary user>` via `mkAliasOptionModule`
- **`pkgs.util.importPins`** — Load content pins from a module's `sources.json` (managed by `pin sources`)

## Host: Quanta

Desktop workstation with KDE Plasma 6, AMD graphics, impermanence (btrfs rollback), and YubiKey authentication.

## Commands

- `nh os switch` / `nh os boot` / `nh os test` / `nh os build` — rebuild through [nh](https://github.com/nix-community/nh), which reads `NH_FLAKE` from `my.flakePath` and shows a diff of what changes.
- `nh clean all --keep 5` — delete old generations and collect garbage.
- `pin` — flake input pins and content pins (`pin status`, `pin update`, `pin freeze <input>`, `pin sources update <name>`).
- `persist` — impermanence paths (`persist list`, `persist add <path>`, `persist junk`).

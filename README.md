# nixos-config

My NixOS configuration following the [Synaptic Standard](https://github.com/SynapticStandard/synaptic-standard).

## Structure

```
nixos/
├── apps/       Per-app modules, each gated by my.apps.<name>.enable
├── core/       Always-on system fundamentals (boot, audio, networking, etc.)
├── modules/    Feature modules with my.* options (impermanence, stylix, etc.)
├── hosts/      Per-host configuration (hardware, user, host-specific settings)
├── flake.nix   Flake entry point
└── hosts.nix   Host builder (auto-discovers hosts/ subdirectories)
```

## Key Concepts

- **`my.*` namespace** - All custom options live under `my` for discoverability
- **`my.desktop.enable`** - Controls workstation vs headless mode
- **`my.apps.*`** - Each app has an explicit enable toggle
- **`my.persistence`** - Unified system + home persistence (used with impermanence)
- **`hm.*`** - Alias for `home-manager.users.<primary user>` via `mkAliasOptionModule`
- **`pkgs.util.importPins`** - Load content pins from a module's `sources.json` (managed by `pin sources`)

## Hosts

A folder under `hosts/` is a host, found by `hosts.nix`, and gets every shared module of `core/`, `apps/` and `modules/` with its options off until the host turns them on.
A host that wants some of them not loaded at all lists them in `hosts/NAME/_without.nix`, as `[ "modules/stylix" "apps/social" ]`.
Such a host is then built as a fork would be that deleted those folders, and whatever they depend on is never fetched for it.

## Host: Quanta

Desktop workstation with KDE Plasma 6, AMD graphics, impermanence (btrfs rollback), and YubiKey authentication.

## Commands

- `nh os switch` / `nh os boot` / `nh os test` / `nh os build` - rebuild through [nh](https://github.com/nix-community/nh), which reads `NH_FLAKE` from `my.flakePath` and shows a diff of what changes.
- `nh clean all --keep 5` - delete old generations and collect garbage.
- `pin` - flake input pins and content pins (`pin status`, `pin update`, `pin freeze <input>`, `pin sources update <name>`).
- `persist` - impermanence paths (`persist list`, `persist add <path>`, `persist junk`).
- `vm-gpu` - start passthrough domains with or without the GPU (`vm-gpu`, `vm-gpu guest virtual --once`, `vm-gpu start guest`). Modes are per host edits on the persistent XML, applied to a transient start only.

## Tests

A test is a `.nix` file in a folder named `_tests`, next to what it tests, and its first line is the command that runs it.
`core/_tests/index.nix` finds them all, and the flake offers them under `tests`, by the folder the `_tests` folder is in:

- `nix build --no-link -L .#tests.lab.lab` runs one test.
- `nix build --no-link -L .#tests.all` runs every test.
- `nix eval .#tests --apply builtins.attrNames` lists the folders that have tests.

Tests of shared modules build on a made up host, `core/_tests/system.nix`, which has every shared module as a host does and names no host of this repository.
A test takes it as `host`: `host.evaluate` gives a system to look at, `host.boot` boots machines, and `host.pkgs` is its packages.
It names the folders it wants left out, as `without = [ "apps/confine" ]`, and never a file to load, so a folder that is deleted takes only its own tests with it.
A test that cannot do without another folder says so, with `host.needs` or the `needs` of `host.boot`, and is skipped where a fork deleted that folder.
`host.bare` is for a module turned on while something it reads from is deleted: it has to evaluate, or to be refused in words that say what it lacks.
`core/_tests/made-up-host.nix` deletes each thing of `apps/` and `modules/` in turn and checks that the rest still evaluates.
`apps/confine` and `apps/flatlock` stand alone and keep tests of their own.

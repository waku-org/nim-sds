# Nix Build System

The Nix configuration builds nim-sds by calling nimble tasks directly (no Makefile involved).

## Architecture

```
flake.nix           — Entry point, defines packages, dev shell, and utility apps
├── nix/default.nix — Build derivation: configures env, runs nim <task> sds.nims
├── nix/shell.nix   — Dev shell: sets up NIMBLE_DIR, nimble-links, NIM_LIB_DIR
└── nix/tools.nix   — Helper: extracts version from sds.nimble
```

The Nim compiler comes from nixpkgs (pinned to 24.11, Nim 2.2.4).
All build logic lives in `sds.nimble` (nimble tasks).

## Shell

```sh
nix develop '.?submodules=1'
```

This automatically:
- Runs `scripts/generate_nimble_links.sh` to set up vendored dependencies
- Exports `NIMBLE_DIR` and `NIM_LIB_DIR`
- Creates the `sds.nims` symlink

## Building

```sh
nix build '.?submodules=1#libsds'
nix build '.?submodules=1#libsds-android-arm64'
```

The `?submodules=1` part is required because vendored dependencies are git submodules.

## Utility apps

```sh
nix run '.#setup'    # Initialize git submodules (run once after clone)
nix run '.#clean'    # Garbage-collect the Nix store
```

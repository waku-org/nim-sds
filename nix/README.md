# Nix Build System

The Nix configuration builds nim-sds by calling nimble tasks directly (no Makefile involved).

## Architecture

```
flake.nix          — Entry point, defines packages and dev shell
├── nix/default.nix — Build derivation: configures env, runs nim <task> sds.nims
├── nix/shell.nix   — Dev shell: sets up NIMBLE_DIR, nimble-links, NIM_LIB_DIR
└── nix/tools.nix   — Helper: extracts version from sds.nimble
```

The `nimbusBuildSystem` flake input is used **only** for its pinned Nim compiler.
All build logic lives in `sds.nimble` (nimble tasks).

## Shell

A development shell can be started using:
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
For more details see: https://github.com/NixOS/nix/issues/4423

## Testing

```sh
nix flake check '.?submodules=1'
```

Or inside the dev shell:
```sh
nimble test
```

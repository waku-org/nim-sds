# Usage

## Shell

A development shell can be started using:
```sh
nix develop
```

## Building

To simply build you can use:
```sh
nix build '.#libsds'
```

It can be also done without even cloning the repo:
```sh
nix build github:waku-org/nim-sds
nix build github:waku-org/nim-sds#libsds-ios
nix build github:waku-org/nim-sds#libsds-android-arm64"
```
Or as a flake input.

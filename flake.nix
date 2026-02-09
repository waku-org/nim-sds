{
  description = "Nim-SDS build flake";

  nixConfig = {
    extra-substituters = [ "https://nix-cache.status.im/" ];
    extra-trusted-public-keys = [ "nix-cache.status.im-1:x/93lOfLU+duPplwMSBR+OlY4+mo+dCN7n0mr4oPwgY=" ];
  };

  inputs = {
    # Pinned commit from nixpkgs 24.11 release (provides Nim 2.2.4).
    # https://github.com/NixOS/nixpkgs/tree/release-24.11
    nixpkgs.url = "github:NixOS/nixpkgs?rev=0ef228213045d2cdb5a169a95d63ded38670b293";
  };

  outputs = { self, nixpkgs }:
    let
      stableSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
        "x86_64-windows"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs stableSystems (system: f system);

      pkgsFor = forAllSystems (
        system: import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
          overlays =  [
            (final: prev: {
              androidEnvCustom = prev.callPackage ./nix/pkgs/android-sdk { };
              androidPkgs = final.androidEnvCustom.pkgs;
              androidShell = final.androidEnvCustom.shell;
            })
          ];
        }
      );

    in rec {
      packages = forAllSystems (system: let
        pkgs = pkgsFor.${system};

        buildTargets = pkgs.callPackage ./nix/default.nix {
          inherit stableSystems;
          src = self;
        };

        skipAndroidOnDarwin = t: !(pkgs.stdenv.isDarwin);
        targets = [
          "libsds-android-arm64"
          "libsds-android-amd64"
          "libsds-android-x86"
          "libsds-android-arm"
        ];
      in rec {
        # non-Android package
        libsds = buildTargets.override { targets = [ "libsds" ]; };

        default = libsds;
      }
      # Generate a package for each target dynamically
      // builtins.listToAttrs (map (name: {
        inherit name;
        value = buildTargets.override { targets = [ name ]; };
      }) targets));

      devShells = forAllSystems (system: {
        default = pkgsFor.${system}.callPackage ./nix/shell.nix {};
      });

      # nix run '.#clean' — garbage-collect the Nix store
      apps = forAllSystems (system: {
        clean = {
          type = "app";
          program = toString (pkgsFor.${system}.writeShellScript "nix-clean" ''
            echo "Removing old Nix generations and unreferenced packages..."
            nix-collect-garbage -d
            echo "Done."
          '');
        };
      });
    };

}

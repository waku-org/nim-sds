{
  description = "Nim-SDS build flake";

  nixConfig = {
    extra-substituters = [ "https://nix-cache.status.im/" ];
    extra-trusted-public-keys = [ "nix-cache.status.im-1:x/93lOfLU+duPplwMSBR+OlY4+mo+dCN7n0mr4oPwgY=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?rev=0ef228213045d2cdb5a169a95d63ded38670b293";
  };

  outputs = { self, nixpkgs }:
    let
      stableSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
        #"x86_64-windows" FIXME: Check if it works.
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
      in rec {
        libsds-android-arm64 = pkgs.callPackage ./nix/default.nix {
          inherit stableSystems;
          src = self;
          targets = ["libsds-android-arm64"];
        };

        libsds = pkgs.callPackage ./nix/default.nix {
          inherit stableSystems;
          src = self;
          targets = ["libsds"];
        };

        default = libsds;
      });

      devShells = forAllSystems (system: {
        default = pkgsFor.${system}.callPackage ./nix/shell.nix {};
      });
    };
}

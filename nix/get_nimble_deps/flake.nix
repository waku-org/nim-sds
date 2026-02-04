{
  description = "Nim project with nimble deps in the store";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # A derivation that installs Nim dependencies
      nimDeps = pkgs.stdenv.mkDerivation {
        pname = "nim-deps";
        version = "1.0";

        src = ./.;  # your Nim project root

        buildInputs = [ pkgs.nim pkgs.git ];

        # Place deps in $out so Nix can track them
        buildPhase = ''
          echo "AAAA inside build"
          mkdir -p $out
          # install nimble packages locally under $out/pkgs2
          NIMBLE_DIR=$out/pkgs2 nimble install -y
        '';

        installPhase = ''
          echo "Deps installed at $out/pkgs2"
        '';
      };
    in

    {
      packages.${system} = {
        myNimProject = pkgs.stdenv.mkDerivation {
          pname = "my-nim-project";
          version = "1.0";

          src = ./.;
          buildInputs = [ pkgs.nim nimDeps ];  # include deps

          buildPhase = ''
            echo "Build using nimDeps at ${nimDeps}/pkgs2"
          '';
        };
      };
    };
}

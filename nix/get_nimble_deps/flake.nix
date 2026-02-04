{
  description = "Nim project with nimble deps in the store";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in
  {
    packages.${system} = {
      nimDeps = pkgs.stdenv.mkDerivation {
        pname = "nim-deps";
        version = "1.0";
        src = ./.;
        buildInputs = [ pkgs.nim pkgs.nimble pkgs.git ];
        buildPhase = ''
          echo "AAAA inside build"
          mkdir -p $out/pkgs2
          NIMBLE_DIR=$out/pkgs2 nimble install -y
        '';
        installPhase = ''
          echo "Deps installed at $out/pkgs2"
        '';
      };
    };
  };
}

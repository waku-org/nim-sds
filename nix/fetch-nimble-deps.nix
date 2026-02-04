{ pkgs ? import <nixpkgs> {} }:

pkgs.stdenv.mkDerivation {
  pname = "nimble-deps";
  version = "0.1";

  src = ./.;

  nativeBuildInputs = [
    pkgs.nim
  ];

  buildPhase = ''
    export HOME=$TMPDIR
    nimble setup -l
  '';

  installPhase = ''
    export HOME=$TMPDIR
    mkdir -p $out
    cp -r ~/.nimble $out/nimble
    NIMBLE_DIR=$out/pkgs2 nimble install -y
  '';

  # These attributes make this a fixed-output derivation
  outputHash = "sha256-Om4BcXK76QrExnKcDzw574l+h75C8yK/EbccpbcvLsQ=";
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
}

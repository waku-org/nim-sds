{ pkgs ? import <nixpkgs> {}, git, nimble }:

pkgs.stdenv.mkDerivation {
  pname = "nimble-deps";
  version = "0.1";

  src = ../.;

  nativeBuildInputs = [
    pkgs.nim git nimble pkgs.cacert
  ];

  configurePhase = ''
    export XDG_CACHE_HOME=$TMPDIR/cache

    export HOME=$TMPDIR/home
    mkdir -p $HOME

    nimble setup -l
  '';

  buildPhase = ''
    echo "Skipping buildPhase in fetch-nimble-deps.nix"
  '';

  installPhase = ''
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export GIT_SSL_CAINFO=$SSL_CERT_FILE

    nimble install -y --depsOnly
  
    echo "AAAA beginning installPhase"
    mkdir -p $out/nimbledeps
    echo "AAAA before ls nimlbledeps in fetch-nimble-deps.nix"
    ls nimbledeps
    ls nimbledeps/pkgs2
    echo "AAAA after ls nimlbledeps in fetch-nimble-deps.nix"
    cp -r nimbledeps/* $out/nimbledeps/*
    echo "AAAA before ls out in fetch-nimble-deps.nix"
    echo "AAAA before ls $out"
    ls $out
    echo "AAAA after ls out in fetch-nimble-deps.nix"
    echo "AAAA end installPhase"
  '';

  # These attributes make this a fixed-output derivation
  outputHash = "sha256-Xtmn7NwzNrX4Qq4WPQ+AbrIK00N8CTtBcx/ZsTTo6eg=";
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
}

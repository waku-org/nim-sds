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

    mkdir -p "$out/"
    cp nimble.paths "$out/"

    ## This is needed to export nimbledeps properly without having different outputHash on each run
    tar cf - \
      --sort=name \
      --owner=0 --group=0 --numeric-owner \
      --mtime='@0' \
      -C "$(dirname nimbledeps)" "$(basename nimbledeps)" \
      | gzip -n > "$out/nimbledeps.tar.gz"
  '';

  # These attributes make this a fixed-output derivation
  outputHash = "sha256-Kg3y+wWEUMAjXY3BCKkH82JKXNOn+HM5K8nEr+x+7Yc=";
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
}

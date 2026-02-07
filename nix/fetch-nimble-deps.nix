{ pkgs ? import <nixpkgs> {}, git, nimble }:

pkgs.stdenv.mkDerivation {
  pname = "nimble-deps";
  version = "0.1";

  src = ../.;

  nativeBuildInputs = [
    pkgs.nim git nimble pkgs.cacert pkgs.gzip pkgs.openssl
  ];

  configurePhase = ''
    export XDG_CACHE_HOME=$NIX_BUILD_TOP/cache
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export OPENSSL_ROOT_DIR=${pkgs.openssl}

    export HOME=$TMPDIR/home
    mkdir -p $HOME
  '';

  buildPhase = ''
    echo "Skipping buildPhase in fetch-nimble-deps.nix"
  '';

  installPhase = ''
    nimble setup -l
    nimble install -y --depsOnly

    mkdir -p "$out/"
    cp nimble.paths "$out/"

    ## Use Nix's gnutar for reproducible tar
    ${pkgs.gnutar}/bin/tar cf - \
      --sort=name \
      --owner=0 --group=0 --numeric-owner \
      --mtime='@0' \
      -C "$(dirname nimbledeps)" "$(basename nimbledeps)" \
      | "${pkgs.gzip}/bin/gzip" -n > "$out/nimbledeps.tar.gz"
  '';

  # These attributes make this a fixed-output derivation
  outputHash = "sha256-Lg2ZcwDb2FB4aYdWrLdv895redK9jnwm31Sma0J5BEc=";
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
}

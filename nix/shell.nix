{
  pkgs ? import <nixpkgs> { },
  nim ? null,
}:

let
  inherit (pkgs) lib stdenv;

in pkgs.mkShell {
  inputsFrom = [
    pkgs.androidShell
  ];

  buildInputs = with pkgs; [
    nim
    which
    git
    cmake
  ] ++ lib.optionals stdenv.isDarwin [
    pkgs.libiconv
  ];

  shellHook = ''
    # Set up nimble-link directory for vendored dependencies
    export NIMBLE_DIR="$(pwd)/vendor/.nimble"
    if [ -f scripts/generate_nimble_links.sh ]; then
      bash scripts/generate_nimble_links.sh
    fi

    # Create sds.nims symlink if missing
    if [ ! -e sds.nims ]; then
      ln -s sds.nimble sds.nims
    fi

    # Tell Nim where to find its standard library headers
    export NIM_LIB_DIR="$(dirname $(dirname $(which nim)))/lib"

    echo ""
    echo "nim-sds dev shell ready. Build commands:"
    echo "  nim libsdsDynamicLinux sds.nims   # Linux shared library"
    echo "  nim libsdsDynamicMac sds.nims     # macOS shared library"
    echo "  nim libsdsStaticLinux sds.nims    # Linux static library"
    echo "  nim libsdsStaticMac sds.nims      # macOS static library"
    echo "  nimble test                        # Run tests"
    echo ""
  '';
}

{
  pkgs ? import <nixpkgs> { },
}:
let
  inherit (pkgs) lib stdenv;
  /* No Android SDK for Darwin aarch64. */
  isMacM1 = stdenv.isDarwin && stdenv.isAarch64;

in pkgs.mkShell {
  inputsFrom = lib.optionals (!isMacM1) [
    pkgs.androidShell
  ];

  buildInputs = with pkgs; [
    which
    git
    cmake
    nim-unwrapped-2_2
  ] ++ lib.optionals stdenv.isDarwin [
    pkgs.libiconv
  ];

  # Avoid compiling Nim itself.
  shellHook = ''
    export MAKEFLAGS='USE_SYSTEM_NIM=1'
  '';
}

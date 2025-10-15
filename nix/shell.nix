{
  pkgs ? import <nixpkgs> { },
}:
let
  optionalDarwinDeps = pkgs.lib.optionals pkgs.stdenv.isDarwin [
    pkgs.libiconv
    pkgs.darwin.apple_sdk.frameworks.Security
  ];
in
pkgs.mkShell {
  inputsFrom = [
    pkgs.androidShell
  ] ++ optionalDarwinDeps;

  buildInputs = with pkgs; [
    which
    git
    cmake
    nim-unwrapped-2_2
  ];

  # Avoid compiling Nim itself.
  shellHook = ''
    export MAKEFLAGS='USE_SYSTEM_NIM=1'
  '';
}

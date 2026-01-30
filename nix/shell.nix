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

  # Avoid compiling Nim itself.
  shellHook = ''
    export USE_SYSTEM_NIM=1
  '';
}

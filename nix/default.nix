{
  config ? {},
  pkgs ? import <nixpkgs> { },
  src ? ../.,
  targets ? ["libsds-android-arm64"],
  verbosity ? 2,
  useSystemNim ? true,
  quickAndDirty ? true,
  stableSystems ? [
    "x86_64-linux" "aarch64-linux"
  ]
}:

assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;
  inherit (lib) any match substring;

  version = substring 0 8 (src.sourceInfo.rev or "dirty");

in stdenv.mkDerivation rec {
  pname = "nim-sds";
  inherit src version;

  buildInputs = with pkgs; [
    openssl
    gmp
    zip
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
  in
    with pkgs; [
      cmake
      which
      lsb-release
      nim-unwrapped-2_2
      fakeGit
  ];

  # Environment variables required for Android builds
  ANDROID_SDK_ROOT = "${pkgs.androidPkgs.sdk}";
  ANDROID_NDK_HOME = "${pkgs.androidPkgs.ndk}";
  NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${version}";
  XDG_CACHE_HOME = "/tmp";

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "USE_SYSTEM_NIM=1"
  ];

  configurePhase = ''
    patchShebangs . vendor/nimbus-build-system > /dev/null
    make nimbus-build-system-paths
    make nimbus-build-system-nimble-dir
  '';

  preBuild = ''
    ln -s sds.nimble sds.nims
  '';

  installPhase = let
    androidManifest = ''
      <manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"org.waku.${pname}\" />
    '';
    containsAndroid = s: (match ".*android.*" s) != null;
  in if (any containsAndroid targets) then ''
    mkdir -p $out/jni
    cp -r build/* $out/jni/
    echo '${androidManifest}' > $out/jni/AndroidManifest.xml
    cd $out
    zip -r libwaku.aar *
  '' else ''
    mkdir -p $out/lib
    cp -r build/* $out/lib
  '';

  meta = with pkgs.lib; {
    description = "Nim implementation of the e2e reliability protocol";
    homepage = "https://github.com/status-im/nim-sds";
    license = licenses.mit;
    platforms = stableSystems;
  };
}

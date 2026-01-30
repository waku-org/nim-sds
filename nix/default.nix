{
  pkgs,
  src ? ../.,
  # Nimbus-build-system package.
  nim ? null,
  # Options: 0,1,2
  verbosity ? 2,
  # Make targets
  targets ? ["libsds-android-arm64"],
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" "x86_64-windows"],
}:

assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;
  inherit (lib) any match substring optionals optionalString;

  # Check if build is for android platform.
  containsAndroid = s: (match ".*android.*" s) != null;
  isAndroidBuild = any containsAndroid targets;

  tools = callPackage ./tools.nix {};
  revision = substring 0 8 (src.rev or src.dirtyRev or "00000000");
  version = tools.findKeyValue "^version = \"([a-f0-9.-]+)\"$" ../sds.nimble;

in stdenv.mkDerivation {
  pname = "nim-sds";
  inherit src;
  version = "${version}-${revision}";

  buildInputs = with pkgs; [
    openssl gmp zip
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
  in with pkgs; [
    nim cmake which fakeGit
  ] ++ optionals stdenv.isLinux [
    pkgs.lsb-release
  ];

  ANDROID_SDK_ROOT = optionalString isAndroidBuild pkgs.androidPkgs.sdk;
  ANDROID_NDK_ROOT = optionalString isAndroidBuild pkgs.androidPkgs.ndk;

  NIMFLAGS = "-d:disableMarchNative";
  XDG_CACHE_HOME = "/tmp";

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    # Built from nimbus-build-system via flake.
    "USE_SYSTEM_NIM=1"
  ];

  configurePhase = ''
    patchShebangs . vendor/nimbus-build-system > /dev/null
    make nimbus-build-system-paths
    make nimbus-build-system-nimble-dir
    ln -s sds.nimble sds.nims
  '';

  installPhase = let
    androidManifest = ''
      <manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"org.waku.nim-sds\" />
    '';
  in if isAndroidBuild then ''
    mkdir -p $out/jni
    cp -r build/* $out/jni/
    echo '${androidManifest}' > $out/jni/AndroidManifest.xml
    cd $out
    zip -r libwaku.aar *
  '' else ''
    mkdir -p $out/lib -p $out/include
    cp build/* $out/lib/
    cp library/libsds.h $out/include/
  '';

  meta = with pkgs.lib; {
    description = "Nim implementation of the e2e reliability protocol";
    homepage = "https://github.com/status-im/nim-sds";
    license = licenses.mit;
    platforms = stableSystems;
  };
}

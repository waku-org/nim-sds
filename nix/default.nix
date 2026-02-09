{
  pkgs,
  src ? ../.,
  # Nimbus-build-system package (used only for pinned Nim compiler).
  nim ? null,
  # Options: 0,1,2
  verbosity ? 2,
  # Build targets (e.g., ["libsds"], ["libsds-android-arm64"])
  targets ? ["libsds"],
  # These are the only platforms tested in CI and considered stable.
  stableSystems ? ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" "x86_64-windows"],
}:

assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) stdenv lib callPackage;
  inherit (lib) any match optionals optionalString substring;

  # Check if build is for android platform.
  containsAndroid = s: (match ".*android.*" s) != null;
  isAndroidBuild = any containsAndroid targets;

  tools = callPackage ./tools.nix {};

  revision = substring 0 8 (src.rev or src.dirtyRev or "00000000");
  version = tools.findKeyValue "^version = \"([a-f0-9.-]+)\"$" ../sds.nimble;

  # Map target names to nimble task + env vars
  targetConfig = {
    "libsds" = rec {
      nimbleTask =
        if stdenv.isDarwin then "libsdsDynamicMac"
        else if stdenv.isLinux then "libsdsDynamicLinux"
        else "libsdsDynamicWindows";
      envVars = {};
    };
    "libsds-static" = rec {
      nimbleTask =
        if stdenv.isDarwin then "libsdsStaticMac"
        else if stdenv.isLinux then "libsdsStaticLinux"
        else "libsdsStaticWindows";
      envVars = {};
    };
    "libsds-android-arm64" = {
      nimbleTask = "libsdsAndroid";
      envVars = {
        ARCH = "arm64";
        ANDROID_ARCH = "aarch64-linux-android";
        ARCH_DIRNAME = "aarch64-linux-android";
        ABIDIR = "arm64-v8a";
      };
    };
    "libsds-android-amd64" = {
      nimbleTask = "libsdsAndroid";
      envVars = {
        ARCH = "amd64";
        ANDROID_ARCH = "x86_64-linux-android";
        ARCH_DIRNAME = "x86_64-linux-android";
        ABIDIR = "x86_64";
      };
    };
    "libsds-android-x86" = {
      nimbleTask = "libsdsAndroid";
      envVars = {
        ARCH = "i386";
        ANDROID_ARCH = "i686-linux-android";
        ARCH_DIRNAME = "i686-linux-android";
        ABIDIR = "x86";
      };
    };
    "libsds-android-arm" = {
      nimbleTask = "libsdsAndroid";
      envVars = {
        ARCH = "arm";
        ANDROID_ARCH = "armv7a-linux-androideabi";
        ARCH_DIRNAME = "arm-linux-androideabi";
        ABIDIR = "armeabi-v7a";
      };
    };
  };

  # Git version for NIM_PARAMS
  gitVersion = substring 0 8 (src.rev or src.dirtyRev or "00000000");

  # Build the nim command for a single target
  buildCommandForTarget = target: let
    cfg = targetConfig.${target};
    nimParams = "-d:git_version=\"${gitVersion}\" -d:release -d:disableMarchNative";
    envExports = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "export ${k}=${v}") cfg.envVars
    );
  in ''
    ${envExports}
    nim ${cfg.nimbleTask} ${nimParams} sds.nims
  '';

in stdenv.mkDerivation {
  pname = "nim-sds";
  inherit src;
  version = "${version}-${revision}";

  env = {
    NIMFLAGS = "-d:disableMarchNative";
  } // lib.optionalAttrs isAndroidBuild {
    ANDROID_SDK_ROOT = pkgs.androidPkgs.sdk;
    ANDROID_NDK_ROOT = pkgs.androidPkgs.ndk;
    ANDROID_TARGET = "30";
  };

  buildInputs = with pkgs; [
    openssl gmp zip
  ];

  nativeBuildInputs = with pkgs; [
    nim cmake which patchelf
  ] ++ optionals stdenv.isLinux [
    pkgs.lsb-release
  ];

  configurePhase = ''
    # Avoid /tmp write errors.
    export XDG_CACHE_HOME=$TMPDIR/cache

    patchShebangs scripts/

    # Set up nimble-link directory for vendored dependencies
    export NIMBLE_DIR="$(pwd)/vendor/.nimble"
    scripts/generate_nimble_links.sh

    # Create sds.nims symlink if missing (nimble task runner needs it)
    if [ ! -e sds.nims ]; then
      ln -s sds.nimble sds.nims
    fi

    # Tell Nim where to find its standard library headers (for iOS C compilation)
    export NIM_LIB_DIR="$(dirname $(dirname $(which nim)))/lib"
  '';

  buildPhase = ''
    export NIMBLE_DIR="$(pwd)/vendor/.nimble"
  '' + lib.optionalString isAndroidBuild ''
    # Add NDK toolchain to PATH so Nim can find clang for Android cross-compilation
    export PATH="$(echo $ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/*/bin):$PATH"
  '' + ''
    ${lib.concatMapStringsSep "\n" buildCommandForTarget targets}
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
    mkdir -p $out/lib $out/include
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

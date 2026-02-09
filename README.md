# nim-e2e-reliability
Nim implementation of the e2e reliability protocol

## Building

### Nix (recommended)

Build the shared library:
```bash
nix build --print-out-paths '.?submodules=1#libsds'
```

Build for Android:
```bash
nix build --print-out-paths '.?submodules=1#libsds-android-arm64'
nix build --print-out-paths '.?submodules=1#libsds-android-amd64'
nix build --print-out-paths '.?submodules=1#libsds-android-x86'
nix build --print-out-paths '.?submodules=1#libsds-android-arm'
```

### Development shell

Enter the dev shell (sets up vendored dependencies automatically):
```bash
nix develop '.?submodules=1'
```

Then build directly with nim:
```bash
# Linux
nim libsdsDynamicLinux sds.nims
nim libsdsStaticLinux sds.nims

# macOS
nim libsdsDynamicMac sds.nims
nim libsdsStaticMac sds.nims

# Windows
nim libsdsDynamicWindows sds.nims
nim libsdsStaticWindows sds.nims
```

Run tests:
```bash
nimble test
```

The built library is output to `build/`.

### Android (without Nix)

Download the latest Android NDK. For example, on Ubuntu with Intel:

```bash
cd ~
wget https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
unzip android-ndk-r27c-linux.zip
```

Then, add the following to your `~/.bashrc` file:
```bash
export ANDROID_NDK_ROOT=$HOME/android-ndk-r27c
export PATH=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH
```

Set up vendored dependencies and build:
```bash
export NIMBLE_DIR="$(pwd)/vendor/.nimble"
bash scripts/generate_nimble_links.sh
ln -s sds.nimble sds.nims

# Set arch-specific env vars, then build
ARCH=arm64 ANDROID_ARCH=aarch64-linux-android ARCH_DIRNAME=aarch64-linux-android \
  nim libsdsAndroid sds.nims
```

| Architecture | ARCH | ANDROID_ARCH | ARCH_DIRNAME |
| ------------ | ---- | ------------ | ------------ |
| arm64 | `arm64` | `aarch64-linux-android` | `aarch64-linux-android` |
| amd64 | `amd64` | `x86_64-linux-android` | `x86_64-linux-android` |
| x86 | `i386` | `i686-linux-android` | `i686-linux-android` |
| arm | `arm` | `armv7a-linux-androideabi` | `arm-linux-androideabi` |

The library is output to `build/libsds.so`.

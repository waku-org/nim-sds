.PHONY: libsds deps

LINK_PCRE := 0

# default target, because it's the first one that doesn't start with '.'
all: | libsds

clean:
	rm -rf build

## Git version
GIT_VERSION ?= $(shell git describe --abbrev=6 --always --tags)
## Compilation parameters. If defined in the CLI the assignments won't be executed
NIM_PARAMS := $(NIM_PARAMS) -d:git_version=\"$(GIT_VERSION)\"

ifeq ($(DEBUG), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:release
else
NIM_PARAMS := $(NIM_PARAMS) -d:debug
endif

STATIC ?= 0

detected_OS ?= Linux
ifeq ($(OS),Windows_NT)
detected_OS := Windows
else
detected_OS := $(shell uname -s)
endif

BUILD_COMMAND ?= libsdsDynamic
ifeq ($(STATIC), 1)
	BUILD_COMMAND = libsdsStatic
endif

ifeq ($(detected_OS),Windows)
	BUILD_COMMAND := $(BUILD_COMMAND)Windows
else ifeq ($(detected_OS),Darwin)
	BUILD_COMMAND := $(BUILD_COMMAND)Mac
	export IOS_SDK_PATH := $(shell xcrun --sdk iphoneos --show-sdk-path)
else ifeq ($(detected_OS),Linux)
	BUILD_COMMAND := $(BUILD_COMMAND)Linux
endif

libsds:
	nim $(BUILD_COMMAND) $(NIM_PARAMS) sds.nims

#####################
## Mobile Bindings ##
#####################
.PHONY: libsds-android \
				libsds-android-precheck \
				libsds-android-arm64 \
				libsds-android-amd64 \
				libsds-android-x86 \
				libsds-android-arm \
				build-libsds-for-android-arch

ANDROID_TARGET ?= 30
ifeq ($(detected_OS),Darwin)
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_ROOT)/toolchains/llvm/prebuilt/darwin-x86_64
else
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_ROOT)/toolchains/llvm/prebuilt/linux-x86_64
endif
# Fixes "clang: not found" errors
PATH := $(ANDROID_TOOLCHAIN_DIR)/bin:$(PATH)

libsds-android-precheck:
ifndef ANDROID_NDK_ROOT
		$(error ANDROID_NDK_ROOT is not set)
endif

build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passC="--sysroot=$(ANDROID_TOOLCHAIN_DIR)/sysroot"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passL="--sysroot=$(ANDROID_TOOLCHAIN_DIR)/sysroot"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passC="--target=$(ANDROID_ARCH)$(ANDROID_TARGET)"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passL="--target=$(ANDROID_ARCH)$(ANDROID_TARGET)"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passC="-I$(ANDROID_TOOLCHAIN_DIR)/sysroot/usr/include"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passC="-I$(ANDROID_TOOLCHAIN_DIR)/sysroot/usr/include/$(ARCH_DIRNAME)"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passL="-L$(ANDROID_TOOLCHAIN_DIR)/sysroot/usr/lib/$(ARCH_DIRNAME)/$(ANDROID_TARGET)"
build-libsds-for-android-arch:
	CC=$(ANDROID_TOOLCHAIN_DIR)/bin/$(ANDROID_ARCH)$(ANDROID_TARGET)-clang \
	ARCH=$(ARCH) ABIDIR=$(ABIDIR) \
	ARCH_DIRNAME=$(ARCH_DIRNAME) \
	ANDROID_ARCH=$(ANDROID_ARCH) \
	ANDROID_TOOLCHAIN_DIR=$(ANDROID_TOOLCHAIN_DIR) \
	$(ENV_SCRIPT) \
	nim libsdsAndroid $(NIM_PARAMS) sds.nims

libsds-android-arm64: ANDROID_ARCH=aarch64-linux-android
libsds-android-arm64: ARCH=arm64
libsds-android-arm64: ABIDIR=arm64-v8a
libsds-android-arm64: ARCH_DIRNAME=aarch64-linux-android
libsds-android-arm64: | libsds-android-precheck build deps
	$(MAKE) build-libsds-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) \
	ARCH=$(ARCH) ABIDIR=$(ABIDIR) ARCH_DIRNAME=$(ARCH_DIRNAME)

libsds-android-amd64: ANDROID_ARCH=x86_64-linux-android
libsds-android-amd64: ARCH=amd64
libsds-android-amd64: ABIDIR=x86_64
libsds-android-amd64: ARCH_DIRNAME=x86_64-linux-android
libsds-android-amd64: | libsds-android-precheck build deps
	$(MAKE) build-libsds-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) \
	ARCH=$(ARCH) ABIDIR=$(ABIDIR) ARCH_DIRNAME=$(ARCH_DIRNAME)

libsds-android-x86: ANDROID_ARCH=i686-linux-android
libsds-android-x86: ARCH=i386
libsds-android-x86: ABIDIR=x86
libsds-android-x86: ARCH_DIRNAME=i686-linux-android
libsds-android-x86: | libsds-android-precheck build deps
	$(MAKE) build-libsds-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) \
	ARCH=$(ARCH) ABIDIR=$(ABIDIR) ARCH_DIRNAME=$(ARCH_DIRNAME)

libsds-android-arm: ANDROID_ARCH=armv7a-linux-androideabi
libsds-android-arm: ARCH=arm
libsds-android-arm: ABIDIR=armeabi-v7a
libsds-android-arm: ARCH_DIRNAME=arm-linux-androideabi
libsds-android-arm: | libsds-android-precheck build deps
# cross-rs target architecture name does not match the one used in android
	$(MAKE) build-libsds-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) \
	ARCH=$(ARCH) ABIDIR=$(ABIDIR) ARCH_DIRNAME=$(ARCH_DIRNAME) \

libsds-android:
ifeq ($(ARCH),arm64)
	$(MAKE) libsds-android-arm64
else ifeq ($(ARCH),amd64)
	$(MAKE) libsds-android-amd64
else ifeq ($(ARCH),x86)
	$(MAKE) libsds-android-x86
# else ifeq ($(ARCH),arm)
# 	$(MAKE) libsds-android-arm
# This target is disabled because on recent versions of cross-rs complain with the following error
# relocation R_ARM_THM_ALU_PREL_11_0 cannot be used against symbol 'stack_init_trampoline_return'; recompile with -fPIC
# It's likely this architecture is not used so we might just not support it.
else
	$(error Unsupported ARCH '$(ARCH)'. Please set ARCH to one of: arm64, arm, amd64, x86)
endif

# Target iOS

libsds-ios: | deps
	$(ENV_SCRIPT) nim libsdsIOS $(NIM_PARAMS) sds.nims


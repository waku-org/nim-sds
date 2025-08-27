.PHONY: libsds

export BUILD_SYSTEM_DIR := vendor/nimbus-build-system
LINK_PCRE := 0

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# default target, because it's the first one that doesn't start with '.'
all: | libsds

sds.nims:
	ln -s sds.nimble $@

update: | update-common
	rm -rf sds.nims && \
		$(MAKE) sds.nims $(HANDLE_OUTPUT)

clean:
	rm -rf build

deps: | sds.nims

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

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

libsds: deps
		rm -f build/libsds*
ifeq ($(STATIC), 1)
		echo -e $(BUILD_MSG) "build/$@.a" && \
		$(ENV_SCRIPT) nim libsdsStatic $(NIM_PARAMS) sds.nims
else
		echo -e $(BUILD_MSG) "build/$@.so" && \
		$(ENV_SCRIPT) nim libsdsDynamic $(NIM_PARAMS) sds.nims
endif
endif

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
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/darwin-x86_64
else
	ANDROID_TOOLCHAIN_DIR := $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/linux-x86_64
endif

libsds-android-precheck:
ifndef ANDROID_NDK_HOME
		$(error ANDROID_NDK_HOME is not set)
endif

build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passC="--sysroot=$(ANDROID_TOOLCHAIN_DIR)/sysroot"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passL="--sysroot=$(ANDROID_TOOLCHAIN_DIR)/sysroot"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passC="--target=$(ANDROID_ARCH)$(ANDROID_TARGET)"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passL="--target=$(ANDROID_ARCH)$(ANDROID_TARGET)"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passC="-I$(ANDROID_TOOLCHAIN_DIR)/sysroot/usr/include"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passC="-I$(ANDROID_TOOLCHAIN_DIR)/sysroot/usr/include/$(ARCH_DIRNAME)"
build-libsds-for-android-arch: NIM_PARAMS := $(NIM_PARAMS) --passL="-L$(ANDROID_TOOLCHAIN_DIR)/sysroot/usr/lib/$(ARCH_DIRNAME)/$(ANDROID_TARGET)"
build-libsds-for-android-arch:
	CPU=$(CPU) ABIDIR=$(ABIDIR) \
	ARCH_DIRNAME=$(ARCH_DIRNAME) \
	ANDROID_ARCH=$(ANDROID_ARCH) \
	ANDROID_COMPILER=$(ANDROID_COMPILER) \
	ANDROID_TOOLCHAIN_DIR=$(ANDROID_TOOLCHAIN_DIR) $(ENV_SCRIPT) \
	nim libsdsAndroid $(NIM_PARAMS) sds.nims

libsds-android-arm64: ANDROID_ARCH=aarch64-linux-android
libsds-android-arm64: CPU=arm64
libsds-android-arm64: ABIDIR=arm64-v8a
libsds-android-arm64: ARCH_DIRNAME=aarch64-linux-android
libsds-android-arm64: | libsds-android-precheck build deps
	$(MAKE) build-libsds-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) \
	CPU=$(CPU) ABIDIR=$(ABIDIR) ARCH_DIRNAME=$(ARCH_DIRNAME) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libsds-android-amd64: ANDROID_ARCH=x86_64-linux-android
libsds-android-amd64: CPU=amd64
libsds-android-amd64: ABIDIR=x86_64
libsds-android-amd64: ARCH_DIRNAME=x86_64-linux-android
libsds-android-amd64: | libsds-android-precheck build deps
	$(MAKE) build-libsds-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) \
	CPU=$(CPU) ABIDIR=$(ABIDIR) ARCH_DIRNAME=$(ARCH_DIRNAME) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libsds-android-x86: ANDROID_ARCH=i686-linux-android
libsds-android-x86: CPU=i386
libsds-android-x86: ABIDIR=x86
libsds-android-x86: ARCH_DIRNAME=i686-linux-android
libsds-android-x86: | libsds-android-precheck build deps
	$(MAKE) build-libsds-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) CROSS_TARGET=$(ANDROID_ARCH) \
	CPU=$(CPU) ABIDIR=$(ABIDIR) ARCH_DIRNAME=$(ARCH_DIRNAME) ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libsds-android-arm: ANDROID_ARCH=armv7a-linux-androideabi
libsds-android-arm: CPU=arm
libsds-android-arm: ABIDIR=armeabi-v7a
libsds-android-arm: ARCH_DIRNAME=arm-linux-androideabi
libsds-android-arm: | libsds-android-precheck build deps
# cross-rs target architecture name does not match the one used in android
	$(MAKE) build-libsds-for-android-arch ANDROID_ARCH=$(ANDROID_ARCH) \
	CROSS_TARGET=armv7-linux-androideabi CPU=$(CPU) ABIDIR=$(ABIDIR) ARCH_DIRNAME=$(ARCH_DIRNAME) \
	ANDROID_COMPILER=$(ANDROID_ARCH)$(ANDROID_TARGET)-clang

libsds-android:
	$(MAKE) libsds-android-amd64
	$(MAKE) libsds-android-arm64
	$(MAKE) libsds-android-x86
# This target is disabled because on recent versions of cross-rs complain with the following error
# relocation R_ARM_THM_ALU_PREL_11_0 cannot be used against symbol 'stack_init_trampoline_return'; recompile with -fPIC
# It's likely this architecture is not used so we might just not support it.
#	$(MAKE) libsds-android-arm
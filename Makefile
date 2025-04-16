.PHONY: libsds

export BUILD_SYSTEM_DIR := vendor/nimbus-build-system
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
.PHONY: libsds

sds.nims:
	ln -s sds.nimble $@

deps: | sds.nims


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
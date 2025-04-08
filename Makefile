.PHONY: libsds

libsds:
	nim c --app:lib --mm:refc --outdir:build library/libsds.nim
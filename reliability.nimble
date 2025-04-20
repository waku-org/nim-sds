# Package
version = "0.1.0"
author = "Waku Team"
description = "E2E Reliability Protocol API"
license = "MIT"
srcDir = "src"

# Dependencies
requires "nim >= 2.0.8"
requires "chronicles"
requires "libp2p"

# Tasks
task test, "Run the test suite":
  exec "nim c -r tests/test_bloom.nim"
  exec "nim c -r tests/test_reliability.nim"

task bindings, "Generate bindings":
  proc compile(libName: string, flags = "") =
    exec "nim c -f " & flags & " -d:release --app:lib --mm:refc --out:" & libName &
      " --outdir:bindings/generated bindings/bindings.nim"

  # Create required directories
  mkDir "bindings/generated"

  when defined(windows):
    compile "reliability.dll"
  elif defined(macosx):
    compile "libsds.dylib.arm",
      "--cpu:arm64 -l:'-target arm64-apple-macos11' -t:'-target arm64-apple-macos11'"
    compile "libsds.dylib.x64",
      "--cpu:amd64 -l:'-target x86_64-apple-macos10.12' -t:'-target x86_64-apple-macos10.12'"
    exec "lipo bindings/generated/libsds.dylib.arm bindings/generated/libsds.dylib.x64 -output bindings/generated/libsds.dylib -create"
  else:
    compile "libsds.so"

# Package
version       = "0.1.0"
author        = "Waku Team"
description   = "E2E Reliability Protocol API"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.8"
requires "chronicles"
requires "libp2p"

# Tasks
task test, "Run the test suite":
  exec "nim c -r tests/test_bloom.nim"
  exec "nim c -r tests/test_reliability.nim"
# Package
version       = "0.1.0"
author        = "Waku Team"
description   = "E2E Reliability Protocol API"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 1.6.0"
requires "nimsha2"
requires "chronicles"

task test, "Run the test suite":
  exec "nim c -r tests/test_reliability.nim"
mode = ScriptMode.Verbose

# Package
version = "0.1.0"
author = "Waku Team"
description = "E2E Reliability Protocol API"
license = "MIT"
srcDir = "src"

# Dependencies
requires "nim >= 2.2.4",
  "chronicles", "chronos", "stew", "stint", "metrics", "libp2p", "results"

proc buildLibrary(name: string, srcDir = "./", params = "", `type` = "static") =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2 ..< paramCount():
    extra_params &= " " & paramStr(i)
  if `type` == "static":
    exec "nim c" & " --out:build/" & name &
      ".a --threads:on --app:staticlib --opt:size --noMain --mm:refc --header --undef:metrics --nimMainPrefix:libsds --skipParentCfg:on " &
      extra_params & " " & srcDir & name & ".nim"
  else:
    exec "nim c" & " --out:build/" & name &
      ".so --threads:on --app:lib --opt:size --noMain --mm:refc --header --undef:metrics --nimMainPrefix:libsds --skipParentCfg:on " &
      extra_params & " " & srcDir & name & ".nim"

# Tasks
task test, "Run the test suite":
  exec "nim c -r tests/test_bloom.nim"
  exec "nim c -r tests/test_reliability.nim"

task libsdsDynamic, "Generate bindings":
  let name = "libsds"
  buildLibrary name,
    "library/",
    """-d:chronicles_line_numbers \
       -d:chronicles_runtime_filtering=on \
       -d:chronicles_sinks="textlines,json" \
       -d:chronicles_default_output_device=Dynamic \
       --warning:Deprecated:off \
       --warning:UnusedImport:on \
       -d:chronicles_log_level=TRACE """,
    "dynamic"

### Mobile Android
proc buildMobileAndroid(srcDir = ".", params = "") =
  let cpu = getEnv("CPU")
  let abiDir = getEnv("ABIDIR")

  let outDir = "build/android/" & abiDir
  if not dirExists outDir:
    mkDir outDir

  var extra_params = params
  for i in 2 ..< paramCount():
    extra_params &= " " & paramStr(i)

  exec "nim c" & " --out:" & outDir &
    "/libsds.so --threads:on --app:lib --opt:size --noMain --mm:refc " &
    "-d:chronicles_sinks=textlines[dynamic] --header --passL:-L" & outdir &
    " --passL:-llog --cpu:" & cpu & " --os:android -d:androidNDK " &
    extra_params & " " & srcDir & "/libsds.nim"

task libsdsAndroid, "Build the mobile bindings for Android":
  let srcDir = "./library"
  let extraParams = "-d:chronicles_log_level=ERROR"
  buildMobileAndroid srcDir, extraParams

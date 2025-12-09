mode = ScriptMode.Verbose

import strutils

# Package
version = "0.1.0"
author = "Waku Team"
description = "E2E Reliability Protocol API"
license = "MIT"
srcDir = "src"

# Dependencies
requires "nim >= 2.2.4",
  "chronicles", "chronos", "stew", "stint", "metrics", "libp2p", "results"

proc buildLibrary(
    outLibNameAndExt: string,
    name: string,
    srcDir = "./",
    params = "",
    `type` = "static",
) =
  if not dirExists "build":
    mkDir "build"
  # allow something like "nim nimbus --verbosity:0 --hints:off nimbus.nims"
  var extra_params = params
  for i in 2 ..< paramCount():
    extra_params &= " " & paramStr(i)
  if `type` == "static":
    exec "nim c" & " --out:build/" & outLibNameAndExt &
      " --threads:on --app:staticlib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds --skipParentCfg:on " &
      extra_params & " " & srcDir & name & ".nim"
  else:
    when defined(windows):
      exec "nim c" & " --out:build/" & outLibNameAndExt &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds --skipParentCfg:off " &
        extra_params & " " & srcDir & name & ".nim"
    else:
      exec "nim c" & " --out:build/" & outLibNameAndExt &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds --skipParentCfg:on " &
        extra_params & " " & srcDir & name & ".nim"

# Tasks
task test, "Run the test suite":
  exec "nim c -r tests/test_bloom.nim"
  exec "nim c -r tests/test_reliability.nim"

task libsdsDynamicWindows, "Generate bindings":
  let outLibNameAndExt = "libsds.dll"
  let name = "libsds"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "dynamic"

task libsdsDynamicLinux, "Generate bindings":
  let outLibNameAndExt = "libsds.so"
  let name = "libsds"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "dynamic"

task libsdsDynamicMac, "Generate bindings":
  let outLibNameAndExt = "libsds.dylib"
  let name = "libsds"

  let arch = getEnv("ARCH")
  let sdkPath = staticExec("xcrun --show-sdk-path").strip()
  let archFlags = (if arch == "arm64": "--cpu:arm64 --passC:\"-arch arm64\" --passL:\"-arch arm64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
                   else: "--cpu:amd64 --passC:\"-arch x86_64\" --passL:\"-arch x86_64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\"")
  buildLibrary outLibNameAndExt,
    name, "library/",
    archFlags & " -d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE",
    "dynamic"

task libsdsStaticWindows, "Generate bindings":
  let outLibNameAndExt = "libsds.lib"
  let name = "libsds"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "static"

task libsdsStaticLinux, "Generate bindings":
  let outLibNameAndExt = "libsds.a"
  let name = "libsds"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "static"

task libsdsStaticMac, "Generate bindings":
  let outLibNameAndExt = "libsds.a"
  let name = "libsds"

  let arch = getEnv("ARCH")
  let sdkPath = staticExec("xcrun --show-sdk-path").strip()
  let archFlags = (if arch == "arm64": "--cpu:arm64 --passC:\"-arch arm64\" --passL:\"-arch arm64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
                   else: "--cpu:amd64 --passC:\"-arch x86_64\" --passL:\"-arch x86_64\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\"")
  buildLibrary outLibNameAndExt,
    name, "library/",
    archFlags & " -d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE",
    "static"

# Build Mobile iOS
proc buildMobileIOS(srcDir = ".", sdkPath = "") =
  echo "Building iOS libsds library"

  let outDir = "build"
  if not dirExists outDir:
    mkDir outDir

  if sdkPath.len == 0:
    quit "Error: Xcode/iOS SDK not found"

  # The output static library
  let cFile = outDir & "/nimcache/@mlibsds.nim.c"
  let oFile = outDir & "/libsds.o"
  let aFile = outDir & "/libsds.a"

  # 1) Generate C sources from Nim (no linking)
  exec "nim c" &
      " --nimcache:build/nimcache --os:ios --cpu:arm64" &
      " --compileOnly:on" &
      " --noMain --mm:refc" &
      " --threads:on --opt:size --header" &
      " --nimMainPrefix:libsds --skipParentCfg:on" &
      " --cc:clang" &
      " --out:" & cFile & " " &
      srcDir & "/libsds.nim"

  exec "clang -arch arm64" &
      " -isysroot " & sdkPath &
      " -I./vendor/nimbus-build-system/vendor/Nim/lib/" &
      " -fembed-bitcode -c " & cFile &
      " -o " & oFile

  exec "ar rcs " & aFile & " " & oFile

  echo "✔ iOS library created: " & aFile

task libsdsIOS, "Build the mobile bindings for iOS":
  let srcDir = "./library"
  let sdkPath = getEnv("IOS_SDK_PATH")
  buildMobileIOS srcDir, sdkPath

### Mobile Android
proc buildMobileAndroid(srcDir = ".", params = "") =
  let cpu = getEnv("CPU")

  let outDir = "build/"
  if not dirExists outDir:
    mkDir outDir

  var extra_params = params
  for i in 2 ..< paramCount():
    extra_params &= " " & paramStr(i)

  exec "nim c" & " --out:" & outDir &
    "/libsds.so --threads:on --app:lib --opt:size --noMain --mm:refc --nimMainPrefix:libsds " &
    "-d:chronicles_sinks=textlines[dynamic] --header --passL:-L" & outdir &
    " --passL:-llog --cpu:" & cpu & " --os:android -d:androidNDK " & extra_params & " " &
    srcDir & "/libsds.nim"

task libsdsAndroid, "Build the mobile bindings for Android":
  let srcDir = "./library"
  let extraParams = "-d:chronicles_log_level=ERROR"
  buildMobileAndroid srcDir, extraParams

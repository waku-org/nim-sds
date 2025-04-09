{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

when defined(linux):
  {.passl: "-Wl,-soname,libsds.so".}

import std/[locks, typetraits, tables, atomics] # Added tables
import chronos
import results
import
  ./sds_thread/sds_thread,
  ./alloc,
  ./ffi_types,
  ./sds_thread/inter_thread_communication/sds_thread_request,
  ../src/[reliability, reliability_utils, message]

################################################################################
### Wrapper around the reliability manager
################################################################################

################################################################################
### Not-exported components

template checkLibsdsParams*(
    ctx: ptr SdsContext, callback: SdsCallBack, userData: pointer
) =
  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

template callEventCallback(ctx: ptr SdsContext, eventName: string, body: untyped) =
  if isNil(ctx[].eventCallback):
    error eventName & " - eventCallback is nil"
    return

  if isNil(ctx[].eventUserData):
    error eventName & " - eventUserData is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[SdsCallBack](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[SdsCallBack](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

proc handleRequest(
    ctx: ptr SdsContext,
    requestType: RequestType,
    content: pointer,
    callback: SdsCallBack,
    userData: pointer,
): cint =
  sds_thread.sendRequestToSdsThread(ctx, requestType, content, callback, userData).isOkOr:
    let msg = "libsds error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_OK

### End of not-exported components
################################################################################

################################################################################
### Library setup

# Every Nim library must have this function called - the name is derived from
# the `--nimMainPrefix` command line option
proc libsdsNimMain() {.importc.}

# To control when the library has been initialized
var initialized: Atomic[bool]

if defined(android):
  # Redirect chronicles to Android System logs
  when compiles(defaultChroniclesStream.outputs[0].writer):
    defaultChroniclesStream.outputs[0].writer = proc(
        logLevel: LogLevel, msg: LogOutputStr
    ) {.raises: [].} =
      echo logLevel, msg

proc initializeLibrary() {.exported.} =
  if not initialized.exchange(true):
    ## Every Nim library needs to call `<yourprefix>NimMain` once exactly, to initialize the Nim runtime.
    ## Being `<yourprefix>` the value given in the optional compilation flag --nimMainPrefix:yourprefix
    libsdsNimMain()
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  when declared(nimGC_setStackBottom):
    var locals {.volatile, noinit.}: pointer
    locals = addr(locals)
    nimGC_setStackBottom(locals)

### End of library setup
################################################################################

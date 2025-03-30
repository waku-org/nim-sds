import std/[locks, typetraits]
import chronos
import results
import ../src/[reliability, reliability_utils, message]

# --- C Type Definitions  ---

type
  CReliabilityManagerHandle* = pointer

  CResult* {.importc: "CResult", header: "bindings.h", bycopy.} = object
    is_ok*: bool
    error_message*: cstring

  CWrapResult* {.importc: "CWrapResult", header: "bindings.h", bycopy.} = object
    base_result*: CResult
    message*: pointer
    message_len*: csize

  CUnwrapResult* {.importc: "CUnwrapResult", header: "bindings.h", bycopy.} = object
    base_result*: CResult
    message*: pointer
    message_len*: csize
    missing_deps*: ptr ptr cstring
    missing_deps_count*: csize

  # Callback Types
  CMessageReadyCallback* = proc (messageID: cstring) {.cdecl, gcsafe, raises: [].}
  CMessageSentCallback* = proc (messageID: cstring) {.cdecl, gcsafe, raises: [].}
  CMissingDependenciesCallback* = proc (messageID: cstring, missingDeps: ptr ptr cstring, missingDepsCount: csize) {.cdecl, gcsafe, raises: [].}
  CPeriodicSyncCallback* = proc (user_data: pointer) {.cdecl, gcsafe, raises: [].}

# --- Memory Management Helpers ---

proc allocCString*(s: string): cstring {.inline, gcsafe.} =
  if s.len == 0: return nil
  result = cast[cstring](allocShared(s.len + 1))
  copyMem(result, s.cstring, s.len + 1)

proc allocSeqByte*(s: seq[byte]): (pointer, csize) {.inline, gcsafe.} =
  if s.len == 0: return (nil, 0)
  let len = s.len
  let bufferPtr = allocShared(len)
  if len > 0:
    copyMem(bufferPtr, cast[pointer](s[0].unsafeAddr), len.Natural)
  return (bufferPtr, len.csize)

proc allocSeqCString*(s: seq[string]): (ptr ptr cstring, csize) {.inline, gcsafe, cdecl.} =
  if s.len == 0: return (nil, 0)
  let count = s.len
  let arrPtr = cast[ptr ptr cstring](allocShared(count * sizeof(cstring)))
  for i in 0..<count:
    let tempCStr: cstring = allocCString(s[i])
    copyMem(addr arrPtr[i], addr tempCStr, sizeof(cstring))
  return (arrPtr, count.csize)

proc freeCString*(cs: cstring) {.inline, gcsafe.} =
  if cs != nil: deallocShared(cs)

proc freeSeqByte*(bufferPtr: pointer) {.inline, gcsafe, cdecl.} =
  if bufferPtr != nil: deallocShared(bufferPtr)

proc freeSeqCString*(arrPtr: ptr ptr cstring, count: csize) {.inline, gcsafe, cdecl.} =
  if arrPtr != nil:
    for i in 0..<count:
      freeCString(cast[cstring](arrPtr[i]))
    deallocShared(arrPtr)

# --- Result Conversion Helpers ---

proc toCResultOk*(): CResult =
  CResult(is_ok: true, error_message: nil)

proc toCResultErr*(err: ReliabilityError): CResult =
  CResult(is_ok: false, error_message: allocCString($err))

proc toCResultErrStr*(errMsg: string): CResult =
  CResult(is_ok: false, error_message: allocCString(errMsg))

# --- Callback Wrappers (Nim -> C) ---
# These still accept the ReliabilityManager instance directly

# These wrappers now need to handle the user_data explicitly if needed,
# but the C callbacks themselves don't take it directly anymore (except PeriodicSync).
# The user_data is stored in rm.cUserData.

proc nimMessageReadyCallback(rm: ReliabilityManager, messageId: MessageID) {.gcsafe.} =
  let cbPtr = rm.cMessageReadyCallback
  if cbPtr != nil:
    let cb = cast[CMessageReadyCallback](cbPtr)
    # Call the C callback without user_data, as per the updated typedef
    cb(messageId.cstring)

proc nimMessageSentCallback(rm: ReliabilityManager, messageId: MessageID) {.gcsafe.} =
  let cbPtr = rm.cMessageSentCallback
  if cbPtr != nil:
    let cb = cast[CMessageSentCallback](cbPtr)
    # Call the C callback without user_data
    cb(messageId.cstring)

proc nimMissingDependenciesCallback(rm: ReliabilityManager, messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} =
  let cbPtr = rm.cMissingDependenciesCallback
  if cbPtr != nil:
    var cDeps = newSeq[cstring](missingDeps.len)
    for i, dep in missingDeps:
      cDeps[i] = dep.cstring
    let cDepsPtr = if cDeps.len > 0: cDeps[0].addr else: nil
    let cb = cast[CMissingDependenciesCallback](cbPtr)
    # Call the C callback without user_data
    cb(messageId.cstring, cast[ptr ptr cstring](cDepsPtr), missingDeps.len.csize)

proc nimPeriodicSyncCallback(rm: ReliabilityManager) {.gcsafe.} =
  let cbPtr = rm.cPeriodicSyncCallback
  if cbPtr != nil:
    let cb = cast[CPeriodicSyncCallback](cbPtr)
    cb(rm.cUserData)

# --- Exported C Functions - Using Opaque Pointer (pointer/void*) ---

proc NewReliabilityManager*(channelIdCStr: cstring): CReliabilityManagerHandle {.exportc, dynlib, cdecl, gcsafe.} =
  let channelId = $channelIdCStr
  if channelId.len == 0:
    echo "Error creating ReliabilityManager: Channel ID cannot be empty"
    return nil # Return nil pointer
  let rmResult = newReliabilityManager(channelId)
  if rmResult.isOk:
    let rm = rmResult.get()
    # Initialize C callback fields to nil
    rm.cMessageReadyCallback = nil
    rm.cMessageSentCallback = nil
    rm.cMissingDependenciesCallback = nil
    rm.cPeriodicSyncCallback = nil
    rm.cUserData = nil
    # Assign Nim wrappers that capture the 'rm' instance directly
    rm.onMessageReady = proc(msgId: MessageID) {.gcsafe.} = nimMessageReadyCallback(rm, msgId)
    rm.onMessageSent = proc(msgId: MessageID) {.gcsafe.} = nimMessageSentCallback(rm, msgId)
    rm.onMissingDependencies = proc(msgId: MessageID, deps: seq[MessageID]) {.gcsafe.} = nimMissingDependenciesCallback(rm, msgId, deps)
    rm.onPeriodicSync = proc() {.gcsafe.} = nimPeriodicSyncCallback(rm)

    # Return the Nim ref object cast to the opaque pointer type
    return cast[CReliabilityManagerHandle](rm)
  else:
    echo "Error creating ReliabilityManager: ", rmResult.error
    return nil # Return nil pointer

proc CleanupReliabilityManager*(handle: CReliabilityManagerHandle) {.exportc, dynlib, cdecl, gcsafe.} =
  if handle != nil:
    # Cast opaque pointer back to Nim ref type
    let rm = cast[ReliabilityManager](handle)
    cleanup(rm) # Call Nim cleanup
    # Nim GC will collect 'rm' eventually as the handle is the only reference
  else:
    echo "Warning: CleanupReliabilityManager called with NULL handle"

proc ResetReliabilityManager*(handle: CReliabilityManagerHandle): CResult {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    return toCResultErrStr("ReliabilityManager handle is NULL")
  let rm = cast[ReliabilityManager](handle) # Cast opaque pointer
  let result = resetReliabilityManager(rm)
  if result.isOk:
    return toCResultOk()
  else:
    return toCResultErr(result.error)

proc WrapOutgoingMessage*(handle: CReliabilityManagerHandle, messageC: pointer, messageLen: csize, messageIdCStr: cstring): CWrapResult {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    return CWrapResult(base_result: toCResultErrStr("ReliabilityManager handle is NULL"))
  let rm = cast[ReliabilityManager](handle) # Cast opaque pointer

  if messageC == nil and messageLen > 0:
     return CWrapResult(base_result: toCResultErrStr("Message pointer is NULL but length > 0"))
  if messageIdCStr == nil:
     return CWrapResult(base_result: toCResultErrStr("Message ID pointer is NULL"))

  let messageId = $messageIdCStr
  var messageNim: seq[byte]
  if messageLen > 0:
    messageNim = newSeq[byte](messageLen)
    copyMem(messageNim[0].addr, messageC, messageLen.Natural)
  else:
    messageNim = @[]

  let wrapResult = wrapOutgoingMessage(rm, messageNim, messageId)
  if wrapResult.isOk:
    let (wrappedDataPtr, wrappedDataLen) = allocSeqByte(wrapResult.get())
    return CWrapResult(
      base_result: toCResultOk(),
      message: wrappedDataPtr,
      message_len: wrappedDataLen
    )
  else:
    return CWrapResult(base_result: toCResultErr(wrapResult.error))

proc UnwrapReceivedMessage*(handle: CReliabilityManagerHandle, messageC: pointer, messageLen: csize): CUnwrapResult {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    return CUnwrapResult(base_result: toCResultErrStr("ReliabilityManager handle is NULL"))
  let rm = cast[ReliabilityManager](handle) # Cast opaque pointer

  if messageC == nil and messageLen > 0:
     return CUnwrapResult(base_result: toCResultErrStr("Message pointer is NULL but length > 0"))

  var messageNim: seq[byte]
  if messageLen > 0:
    messageNim = newSeq[byte](messageLen)
    copyMem(messageNim[0].addr, messageC, messageLen.Natural)
  else:
    messageNim = @[]

  let unwrapResult = unwrapReceivedMessage(rm, messageNim)
  if unwrapResult.isOk:
    let (unwrappedContent, missingDepsNim) = unwrapResult.get()
    let (contentPtr, contentLen) = allocSeqByte(unwrappedContent)
    let (depsPtr, depsCount) = allocSeqCString(missingDepsNim)
    return CUnwrapResult(
      base_result: toCResultOk(),
      message: contentPtr,
      message_len: contentLen,
      missing_deps: depsPtr,
      missing_deps_count: depsCount
    )
  else:
    return CUnwrapResult(base_result: toCResultErr(unwrapResult.error))

proc MarkDependenciesMet*(handle: CReliabilityManagerHandle, messageIDsC: ptr ptr cstring, count: csize): CResult {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    return toCResultErrStr("ReliabilityManager handle is NULL")
  let rm = cast[ReliabilityManager](handle) # Cast opaque pointer

  if messageIDsC == nil and count > 0:
    return toCResultErrStr("MessageIDs pointer is NULL but count > 0")

  var messageIDsNim = newSeq[string](count)
  for i in 0..<count:
    let currentCStr = cast[cstring](messageIDsC[i])
    if currentCStr != nil:
      messageIDsNim[i] = $currentCStr
    else:
      return toCResultErrStr("NULL message ID found in array")

  let result = markDependenciesMet(rm, messageIDsNim)
  if result.isOk:
    return toCResultOk()
  else:
    return toCResultErr(result.error)

proc RegisterCallbacks*(handle: CReliabilityManagerHandle,
                        cMessageReady: pointer,
                        cMessageSent: pointer,
                        cMissingDependencies: pointer,
                        cPeriodicSync: pointer,
                        cUserDataPtr: pointer) {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    echo "Error: Cannot register callbacks: NULL ReliabilityManager handle"
    return
  let rm = cast[ReliabilityManager](handle) # Cast opaque pointer
  # Lock the specific manager instance while modifying its fields
  withLock rm.lock:
    rm.cMessageReadyCallback = cMessageReady
    rm.cMessageSentCallback = cMessageSent
    rm.cMissingDependenciesCallback = cMissingDependencies
    rm.cPeriodicSyncCallback = cPeriodicSync
    rm.cUserData = cUserDataPtr

proc StartPeriodicTasks*(handle: CReliabilityManagerHandle) {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    echo "Error: Cannot start periodic tasks: NULL ReliabilityManager handle"
    return
  let rm = cast[ReliabilityManager](handle) # Cast opaque pointer
  startPeriodicTasks(rm)

# --- Memory Freeing Functions - Added cdecl ---

proc FreeCResultError*(result: CResult) {.exportc, dynlib, gcsafe, cdecl.} =
  freeCString(result.error_message)

proc FreeCWrapResult*(result: CWrapResult) {.exportc, dynlib, gcsafe, cdecl.} =
  freeCString(result.base_result.error_message)
  freeSeqByte(result.message)

proc FreeCUnwrapResult*(result: CUnwrapResult) {.exportc, dynlib, gcsafe, cdecl.} =
  freeCString(result.base_result.error_message)
  freeSeqByte(result.message)
  freeSeqCString(result.missing_deps, result.missing_deps_count)

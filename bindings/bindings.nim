import std/typetraits
import system, chronos, results
import ../src/[reliability, reliability_utils, message]

type CReliabilityManagerHandle* = pointer

type
  CResult* {.importc: "CResult", header: "bindings.h", bycopy.} = object
    is_ok*: bool
    error_message*: cstring

  CWrapResult* {.importc: "CWrapResult", header: "bindings.h", bycopy.} = object
    base_result*: CResult
    message*: pointer
    message_len*: csize_t

  CUnwrapResult* {.importc: "CUnwrapResult", header: "bindings.h", bycopy.} = object
    base_result*: CResult
    message*: pointer
    message_len*: csize_t
    missing_deps*: ptr cstring
    missing_deps_count*: csize_t

# --- Memory Management Helpers ---

proc allocCString*(s: string): cstring {.inline, gcsafe.} =
  if s.len == 0:
    return nil
  result = cast[cstring](allocShared(s.len + 1))
  copyMem(result, s.cstring, s.len + 1)

proc allocSeqByte*(s: seq[byte]): (pointer, csize_t) {.inline, gcsafe.} =
  if s.len == 0:
    return (nil, 0)
  let len = s.len
  let bufferPtr = allocShared(len)
  if len > 0:
    copyMem(bufferPtr, cast[pointer](s[0].unsafeAddr), len.Natural)
  return (bufferPtr, len.csize_t)

proc allocSeqCString*(
    s: seq[string]
): (ptr cstring, csize_t) {.inline, gcsafe, cdecl.} =
  if s.len == 0:
    return (nil, 0)
  let count = s.len
  # Allocate memory for 'count' cstring pointers, cast to ptr UncheckedArray
  let arrPtr = cast[ptr UncheckedArray[cstring]](allocShared(count * sizeof(cstring)))
  for i in 0 ..< count:
    # Allocate each string and store its pointer in the array using unchecked array indexing
    arrPtr[i] = allocCString(s[i])
  # Return pointer to the first element, cast back to ptr cstring
  return (cast[ptr cstring](arrPtr), count.csize_t)

proc freeCString*(cs: cstring) {.inline, gcsafe.} =
  if cs != nil:
    deallocShared(cs)

proc freeSeqByte*(bufferPtr: pointer) {.inline, gcsafe, cdecl.} =
  if bufferPtr != nil:
    deallocShared(bufferPtr)

proc freeSeqCString*(arrPtr: ptr cstring, count: csize_t) {.inline, gcsafe, cdecl.} =
  if arrPtr != nil:
    # Cast to ptr UncheckedArray for proper iteration/indexing before freeing
    let arr = cast[ptr UncheckedArray[cstring]](arrPtr)
    for i in 0 ..< count:
      freeCString(arr[i]) # Free each individual cstring
    deallocShared(arrPtr) # Free the array pointer itself

# --- Result Conversion Helpers ---

proc toCResultOk*(): CResult =
  CResult(is_ok: true, error_message: nil)

proc toCResultErr*(err: ReliabilityError): CResult =
  CResult(is_ok: false, error_message: allocCString($err))

proc toCResultErrStr*(errMsg: string): CResult =
  CResult(is_ok: false, error_message: allocCString(errMsg))

# --- Callback Wrappers (Nim -> C) ---
# These wrappers retrieve the C callback info from the ReliabilityManager object.

proc nimMessageReadyCallback(rm: ReliabilityManager, messageId: MessageID) {.gcsafe.} =
  setupForeignThreadGc() # Setup GC for this Go thread
  defer:
    tearDownForeignThreadGc() # Ensure teardown even if callback errors

  let handle = cast[CReliabilityManagerHandle](rm) # Still use handle for C side
  let cb = rm.cCallback

  if cb == nil:
    return

  # Pass handle, event type, and messageId
  cb(handle, EVENT_MESSAGE_READY, cast[pointer](messageId.cstring), nil, 0)

proc nimMessageSentCallback(rm: ReliabilityManager, messageId: MessageID) {.gcsafe.} =
  setupForeignThreadGc()
  defer:
    tearDownForeignThreadGc()

  let handle = cast[CReliabilityManagerHandle](rm)
  let cb = rm.cCallback

  if cb == nil:
    return

  cb(handle, EVENT_MESSAGE_SENT, cast[pointer](messageId.cstring), nil, 0)

proc nimMissingDependenciesCallback(
    rm: ReliabilityManager, messageId: MessageID, missingDeps: seq[MessageID]
) {.gcsafe.} =
  setupForeignThreadGc()
  defer:
    tearDownForeignThreadGc()

  let handle = cast[CReliabilityManagerHandle](rm)
  let cb = rm.cCallback

  if cb == nil:
    return

  # Prepare data for the callback
  var cDepsPtr: ptr cstring = nil
  var cDepsCount: csize_t = 0
  var cDepsNim: seq[cstring] = @[] # Keep Nim seq alive during call
  if missingDeps.len > 0:
    cDepsNim = newSeq[cstring](missingDeps.len)
    for i, dep in missingDeps:
      cDepsNim[i] = dep.cstring # Nim GC manages these cstrings via the seq
    cDepsPtr = cast[ptr cstring](cDepsNim[0].addr)
    cDepsCount = missingDeps.len.csize_t

  cb(
    handle,
    EVENT_MISSING_DEPENDENCIES,
    cast[pointer](messageId.cstring),
    cast[pointer](cDepsPtr),
    cDepsCount,
  )

proc nimPeriodicSyncCallback(rm: ReliabilityManager) {.gcsafe.} =
  setupForeignThreadGc()
  defer:
    tearDownForeignThreadGc()

  let handle = cast[CReliabilityManagerHandle](rm)
  let cb = rm.cCallback

  if cb == nil:
    return

  cb(handle, EVENT_PERIODIC_SYNC, nil, nil, 0)

# --- Exported C Functions ---

proc NewReliabilityManager*(
    channelIdCStr: cstring
): CReliabilityManagerHandle {.exportc, dynlib, cdecl, gcsafe.} =
  let channelId = $channelIdCStr
  if channelId.len == 0:
    return nil # Return nil pointer
  let rmResult = newReliabilityManager(channelId)
  if rmResult.isOk:
    let rm = rmResult.get()
    rm.onMessageReady = proc(rmArg: ReliabilityManager, msgId: MessageID) {.gcsafe.} =
      nimMessageReadyCallback(rmArg, msgId)
    rm.onMessageSent = proc(rmArg: ReliabilityManager, msgId: MessageID) {.gcsafe.} =
      nimMessageSentCallback(rmArg, msgId)
    rm.onMissingDependencies = proc(
        rmArg: ReliabilityManager, msgId: MessageID, deps: seq[MessageID]
    ) {.gcsafe.} =
      nimMissingDependenciesCallback(rmArg, msgId, deps)
    rm.onPeriodicSync = proc(rmArg: ReliabilityManager) {.gcsafe.} =
      nimPeriodicSyncCallback(rmArg)

    # Return the Nim ref object cast to the opaque pointer type
    let handle = cast[CReliabilityManagerHandle](rm)
    GC_ref(rm) # Prevent GC from moving the object while Go holds the handle
    return handle
  else:
    return nil

proc CleanupReliabilityManager*(
    handle: CReliabilityManagerHandle
) {.exportc, dynlib, cdecl.} =
  let handlePtr = handle
  if handlePtr != nil:
    # Cast opaque pointer back to Nim ref type
    let rm = cast[ReliabilityManager](handlePtr)
    cleanup(rm)
    GC_unref(rm) # Allow GC to collect the object now that Go is done
  else:
    discard

proc ResetReliabilityManager*(
    handle: CReliabilityManagerHandle
): CResult {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    return toCResultErrStr("ReliabilityManager handle is NULL")
  let rm = cast[ReliabilityManager](handle)
  let opResult = resetReliabilityManager(rm)
  if opResult.isOk:
    return toCResultOk()
  else:
    return toCResultErr(opResult.error)

proc WrapOutgoingMessage*(
    handle: CReliabilityManagerHandle,
    messageC: pointer,
    messageLen: csize_t,
    messageIdCStr: cstring,
): CWrapResult {.exportc, dynlib, cdecl.} =
  if handle == nil:
    return
      CWrapResult(base_result: toCResultErrStr("ReliabilityManager handle is NULL"))
  let rm = cast[ReliabilityManager](handle)

  if messageC == nil and messageLen > 0:
    return CWrapResult(
      base_result: toCResultErrStr("Message pointer is NULL but length > 0")
    )
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
      base_result: toCResultOk(), message: wrappedDataPtr, message_len: wrappedDataLen
    )
  else:
    return CWrapResult(base_result: toCResultErr(wrapResult.error))

proc UnwrapReceivedMessage*(
    handle: CReliabilityManagerHandle, messageC: pointer, messageLen: csize_t
): CUnwrapResult {.exportc, dynlib, cdecl.} =
  if handle == nil:
    return
      CUnwrapResult(base_result: toCResultErrStr("ReliabilityManager handle is NULL"))
  let rm = cast[ReliabilityManager](handle)

  if messageC == nil and messageLen > 0:
    return CUnwrapResult(
      base_result: toCResultErrStr("Message pointer is NULL but length > 0")
    )

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
      missing_deps_count: depsCount,
    )
  else:
    return CUnwrapResult(base_result: toCResultErr(unwrapResult.error))

proc MarkDependenciesMet*(
    handle: CReliabilityManagerHandle, messageIDsC: ptr cstring, count: csize_t
): CResult {.exportc, dynlib, cdecl.} =
  if handle == nil:
    return toCResultErrStr("ReliabilityManager handle is NULL")
  let rm = cast[ReliabilityManager](handle)

  if messageIDsC == nil and count > 0:
    return toCResultErrStr("MessageIDs pointer is NULL but count > 0")

  var messageIDsNim = newSeq[string](count)
  # Cast to ptr UncheckedArray for indexing
  let messageIDsCArray = cast[ptr UncheckedArray[cstring]](messageIDsC)
  for i in 0 ..< count:
    let currentCStr = messageIDsCArray[i]
    if currentCStr != nil:
      messageIDsNim[i] = $currentCStr
    else:
      return toCResultErrStr("NULL message ID found in array")

  let opResult = markDependenciesMet(rm, messageIDsNim)
  if opResult.isOk:
    return toCResultOk()
  else:
    return toCResultErr(opResult.error)

proc RegisterCallback*(
    handle: CReliabilityManagerHandle,
    cEventCallback: CEventCallback,
    cUserDataPtr: pointer,
) {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    return
  let rm = cast[ReliabilityManager](handle)
  rm.cCallback = cEventCallback
  rm.cUserData = cUserDataPtr

proc StartPeriodicTasks*(handle: CReliabilityManagerHandle) {.exportc, dynlib, cdecl.} =
  if handle == nil:
    return
  let rm = cast[ReliabilityManager](handle)
  startPeriodicTasks(rm)

# --- Memory Freeing Functions ---

proc FreeCResultError*(result: CResult) {.exportc, dynlib, gcsafe, cdecl.} =
  freeCString(result.error_message)

proc FreeCWrapResult*(result: CWrapResult) {.exportc, dynlib, gcsafe, cdecl.} =
  freeCString(result.base_result.error_message)
  freeSeqByte(result.message)

proc FreeCUnwrapResult*(result: CUnwrapResult) {.exportc, dynlib, gcsafe, cdecl.} =
  freeCString(result.base_result.error_message)
  freeSeqByte(result.message)
  freeSeqCString(result.missing_deps, result.missing_deps_count)

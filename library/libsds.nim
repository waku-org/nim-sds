import std/[locks, typetraits, tables] # Added tables
import chronos
import results
import ../src/[reliability, reliability_utils, message]

type CReliabilityManagerHandle* = pointer

type
  # Callback Types (Imported from C Header)
  CEventType* {.importc: "CEventType", header: "libsds.h", pure.} = enum
    EVENT_MESSAGE_READY = 1
    EVENT_MESSAGE_SENT = 2
    EVENT_MISSING_DEPENDENCIES = 3
    EVENT_PERIODIC_SYNC = 4

  CEventCallback* = proc(
    handle: pointer,
    eventType: CEventType,
    data1: pointer,
    data2: pointer,
    data3: csize_t,
  ) {.cdecl.} # Use csize_t

  CResult* {.importc: "CResult", header: "libsds.h", bycopy.} = object
    is_ok*: bool
    error_message*: cstring

  CWrapResult* {.importc: "CWrapResult", header: "libsds.h", bycopy.} = object
    base_result*: CResult
    message*: pointer
    message_len*: csize_t

  CUnwrapResult* {.importc: "CUnwrapResult", header: "libsds.h", bycopy.} = object
    base_result*: CResult
    message*: pointer
    message_len*: csize_t
    missing_deps*: ptr cstring
    missing_deps_count*: csize_t

# --- Callback Registry ---
type CallbackRegistry = Table[CReliabilityManagerHandle, CEventCallback]

var
  callbackRegistry: CallbackRegistry
  registryLock: Lock

initLock(registryLock)

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

# Corrected to accept ptr cstring
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
# These wrappers call the single global Go callback relay.

proc nimMessageReadyCallback(rm: ReliabilityManager, messageId: MessageID) =
  echo "[Nim Binding] nimMessageReadyCallback called for: ", messageId
  let handle = cast[CReliabilityManagerHandle](rm)
  var cb: CEventCallback
  withLock registryLock:
    if not callbackRegistry.hasKey(handle):
      echo "[Nim Binding] No callback registered for handle: ", cast[int](handle)
      return
    cb = callbackRegistry[handle]

  # Pass handle, event type, and messageId (as data1)
  cb(handle, EVENT_MESSAGE_READY, cast[pointer](messageId.cstring), nil, 0)

proc nimMessageSentCallback(rm: ReliabilityManager, messageId: MessageID) =
  echo "[Nim Binding] nimMessageSentCallback called for: ", messageId
  let handle = cast[CReliabilityManagerHandle](rm)
  var cb: CEventCallback
  withLock registryLock:
    if not callbackRegistry.hasKey(handle):
      echo "[Nim Binding] No callback registered for handle: ", cast[int](handle)
      return
    cb = callbackRegistry[handle]

  cb(handle, EVENT_MESSAGE_SENT, cast[pointer](messageId.cstring), nil, 0)

proc nimMissingDependenciesCallback(
    rm: ReliabilityManager, messageId: MessageID, missingDeps: seq[MessageID]
) =
  echo "[Nim Binding] nimMissingDependenciesCallback called for: ",
    messageId, " with deps: ", $missingDeps
  let handle = cast[CReliabilityManagerHandle](rm)
  var cb: CEventCallback
  withLock registryLock:
    if not callbackRegistry.hasKey(handle):
      echo "[Nim Binding] No callback registered for handle: ", cast[int](handle)
      return
    cb = callbackRegistry[handle]

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

proc nimPeriodicSyncCallback(rm: ReliabilityManager) =
  echo "[Nim Binding] nimPeriodicSyncCallback called"
  let handle = cast[CReliabilityManagerHandle](rm)
  var cb: CEventCallback
  withLock registryLock:
    if not callbackRegistry.hasKey(handle):
      echo "[Nim Binding] No callback registered for handle: ", cast[int](handle)
      return
    cb = callbackRegistry[handle]

  cb(handle, EVENT_PERIODIC_SYNC, nil, nil, 0)

# --- Exported C Functions - Using Opaque Pointer ---

proc NewReliabilityManager*(
    channelIdCStr: cstring
): CReliabilityManagerHandle {.exportc, dynlib, cdecl, gcsafe.} =
  let channelId = $channelIdCStr
  if channelId.len == 0:
    echo "Error creating ReliabilityManager: Channel ID cannot be empty"
    return nil # Return nil pointer
  let rmResult = newReliabilityManager(channelId)
  if rmResult.isOk:
    let rm = rmResult.get()
    # Assign anonymous procs that capture 'rm' and call the wrappers
    # Ensure signatures match the non-gcsafe fields in ReliabilityManager
    rm.onMessageReady = proc(msgId: MessageID) =
      nimMessageReadyCallback(rm, msgId)
    rm.onMessageSent = proc(msgId: MessageID) =
      nimMessageSentCallback(rm, msgId)
    rm.onMissingDependencies = proc(msgId: MessageID, deps: seq[MessageID]) =
      nimMissingDependenciesCallback(rm, msgId, deps)
    rm.onPeriodicSync = proc() =
      nimPeriodicSyncCallback(rm)

    # Return the Nim ref object cast to the opaque pointer type
    let handle = cast[CReliabilityManagerHandle](rm)
    GC_ref(rm) # Prevent GC from moving the object while Go holds the handle
    return handle
  else:
    echo "Error creating ReliabilityManager: ", rmResult.error
    return nil # Return nil pointer

proc CleanupReliabilityManager*(
    handle: CReliabilityManagerHandle
) {.exportc, dynlib, cdecl.} =
  let handlePtr = handle
  if handlePtr != nil:
    # Go side should handle removing the handle from its registry.
    # We just need to unref the Nim object.
    # No need to interact with gEventCallback here.

    # Cast opaque pointer back to Nim ref type
    let rm = cast[ReliabilityManager](handlePtr)
    cleanup(rm) # Call Nim cleanup
    GC_unref(rm) # Allow GC to collect the object now that Go is done
  else:
    echo "Warning: CleanupReliabilityManager called with NULL handle"

proc ResetReliabilityManager*(
    handle: CReliabilityManagerHandle
): CResult {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    return toCResultErrStr("ReliabilityManager handle is NULL")
  let rm = cast[ReliabilityManager](handle)
  let result = resetReliabilityManager(rm)
  if result.isOk:
    return toCResultOk()
  else:
    return toCResultErr(result.error)

proc WrapOutgoingMessage*(
    handle: CReliabilityManagerHandle,
    messageC: pointer,
    messageLen: csize_t,
    messageIdCStr: cstring,
): CWrapResult {.exportc, dynlib, cdecl.} = # Keep non-gcsafe
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
): CUnwrapResult {.exportc, dynlib, cdecl.} = # Keep non-gcsafe
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
): CResult {.exportc, dynlib, cdecl.} = # Keep non-gcsafe
  if handle == nil:
    return toCResultErrStr("ReliabilityManager handle is NULL")
  let rm = cast[ReliabilityManager](handle)

  if messageIDsC == nil and count > 0:
    return toCResultErrStr("MessageIDs pointer is NULL but count > 0")

  var messageIDsNim = newSeq[string](count)
  # Cast to ptr UncheckedArray for indexing
  let messageIDsCArray = cast[ptr UncheckedArray[cstring]](messageIDsC)
  for i in 0 ..< count:
    let currentCStr = messageIDsCArray[i] # Use unchecked array indexing
    if currentCStr != nil:
      messageIDsNim[i] = $currentCStr
    else:
      return toCResultErrStr("NULL message ID found in array")

  let result = markDependenciesMet(rm, messageIDsNim)
  if result.isOk:
    return toCResultOk()
  else:
    return toCResultErr(result.error)

proc RegisterCallback*(
    handle: CReliabilityManagerHandle,
    cEventCallback: CEventCallback,
    cUserDataPtr: pointer,
) {.exportc, dynlib, cdecl.} =
  withLock registryLock:
    callbackRegistry[handle] = cEventCallback
    echo "[Nim Binding] Registered callback for handle: ", cast[int](handle)

proc StartPeriodicTasks*(handle: CReliabilityManagerHandle) {.exportc, dynlib, cdecl.} =
  if handle == nil:
    echo "Error: Cannot start periodic tasks: NULL ReliabilityManager handle"
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

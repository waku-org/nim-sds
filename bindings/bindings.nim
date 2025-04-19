import std/typetraits
import system # for GC thread setup/teardown
import chronos
import results
import ../src/[reliability, reliability_utils, message]

type CReliabilityManagerHandle* = pointer

type
  # Callback Types (Imported from C Header)
  CEventType* {.importc: "CEventType", header: "bindings.h", pure.} = enum
    EVENT_MESSAGE_READY = 1
    EVENT_MESSAGE_SENT = 2
    EVENT_MISSING_DEPENDENCIES = 3
    EVENT_PERIODIC_SYNC = 4

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
    echo "[Nim Binding][allocCString] Allocating empty string"
    return nil
  result = cast[cstring](allocShared(s.len + 1))
  copyMem(result, s.cstring, s.len + 1)
  echo "[Nim Binding][allocCString] Allocated cstring at ",
    cast[int](result), " for: ", s

proc allocSeqByte*(s: seq[byte]): (pointer, csize_t) {.inline, gcsafe.} =
  if s.len == 0:
    echo "[Nim Binding][allocSeqByte] Allocating empty seq[byte]"
    return (nil, 0)
  let len = s.len
  let bufferPtr = allocShared(len)
  if len > 0:
    copyMem(bufferPtr, cast[pointer](s[0].unsafeAddr), len.Natural)
  echo "[Nim Binding][allocSeqByte] Allocated buffer at ",
    cast[int](bufferPtr), " of length ", len
  return (bufferPtr, len.csize_t)

proc allocSeqCString*(
    s: seq[string]
): (ptr cstring, csize_t) {.inline, gcsafe, cdecl.} =
  if s.len == 0:
    echo "[Nim Binding][allocSeqCString] Allocating empty seq[string]"
    return (nil, 0)
  let count = s.len
  # Allocate memory for 'count' cstring pointers, cast to ptr UncheckedArray
  let arrPtr = cast[ptr UncheckedArray[cstring]](allocShared(count * sizeof(cstring)))
  for i in 0 ..< count:
    # Allocate each string and store its pointer in the array using unchecked array indexing
    arrPtr[i] = allocCString(s[i])
    echo "[Nim Binding][allocSeqCString] Allocated cstring for missingDep[",
      i, "]: ", s[i], " at ", cast[int](arrPtr[i])
  # Return pointer to the first element, cast back to ptr cstring
  echo "[Nim Binding][allocSeqCString] Allocated array at ",
    cast[int](arrPtr), " with count ", count
  return (cast[ptr cstring](arrPtr), count.csize_t)

proc freeCString*(cs: cstring) {.inline, gcsafe.} =
  if cs != nil:
    echo "[Nim Binding][freeCString] Freeing cstring at ", cast[int](cs)
    deallocShared(cs)

proc freeSeqByte*(bufferPtr: pointer) {.inline, gcsafe, cdecl.} =
  if bufferPtr != nil:
    echo "[Nim Binding][freeSeqByte] Freeing buffer at ", cast[int](bufferPtr)
    deallocShared(bufferPtr)

# Corrected to accept ptr cstring
proc freeSeqCString*(arrPtr: ptr cstring, count: csize_t) {.inline, gcsafe, cdecl.} =
  if arrPtr != nil:
    echo "[Nim Binding][freeSeqCString] Freeing array at ",
      cast[int](arrPtr), " with count ", count
    # Cast to ptr UncheckedArray for proper iteration/indexing before freeing
    let arr = cast[ptr UncheckedArray[cstring]](arrPtr)
    for i in 0 ..< count:
      echo "[Nim Binding][freeSeqCString] Freeing cstring[",
        i, "] at ", cast[int](arr[i])
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

  echo "[Nim Binding] nimMessageReadyCallback called for: ", messageId
  let handle = cast[CReliabilityManagerHandle](rm) # Still use handle for C side
  let cb = rm.cCallback

  if cb == nil:
    echo "[Nim Binding] No C callback stored in handle: ", cast[int](handle)
    return

  # Pass handle, event type, and messageId (as data1), plus user_data
  cb(handle, EVENT_MESSAGE_READY, cast[pointer](messageId.cstring), nil, 0)

proc nimMessageSentCallback(rm: ReliabilityManager, messageId: MessageID) {.gcsafe.} =
  setupForeignThreadGc()
  defer:
    tearDownForeignThreadGc()

  echo "[Nim Binding] nimMessageSentCallback called for: ", messageId
  let handle = cast[CReliabilityManagerHandle](rm)
  let cb = rm.cCallback

  if cb == nil:
    echo "[Nim Binding] No C callback stored in handle: ", cast[int](handle)
    return

  cb(handle, EVENT_MESSAGE_SENT, cast[pointer](messageId.cstring), nil, 0)

proc nimMissingDependenciesCallback(
    rm: ReliabilityManager, messageId: MessageID, missingDeps: seq[MessageID]
) {.gcsafe.} =
  setupForeignThreadGc()
  defer:
    tearDownForeignThreadGc()

  echo "[Nim Binding] nimMissingDependenciesCallback called for: ",
    messageId, " with deps: ", $missingDeps
  let handle = cast[CReliabilityManagerHandle](rm)
  let cb = rm.cCallback

  if cb == nil:
    echo "[Nim Binding] No C callback stored in handle: ", cast[int](handle)
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
    # Ensure cDepsNim stays alive during the call if cDepsPtr points into it
    # Using allocSeqCString might be safer if Go needs to hold onto the data.
    # For now, assuming Go copies the data immediately during the callback.

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

  echo "[Nim Binding] nimPeriodicSyncCallback called"
  let handle = cast[CReliabilityManagerHandle](rm)
  let cb = rm.cCallback

  if cb == nil:
    echo "[Nim Binding] No C callback stored in handle: ", cast[int](handle)
    return

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
    echo "Error creating ReliabilityManager: ", rmResult.error
    return nil # Return nil pointer

proc CleanupReliabilityManager*(
    handle: CReliabilityManagerHandle
) {.exportc, dynlib, cdecl.} =
  let handlePtr = handle
  echo "[Nim Binding][Cleanup] Called with handle: ", cast[int](handlePtr)
  if handlePtr != nil:
    # Go side should handle removing the handle from its registry.
    # We just need to unref the Nim object.

    # Cast opaque pointer back to Nim ref type
    let rm = cast[ReliabilityManager](handlePtr)
    echo "[Nim Binding][Cleanup] Calling Nim core cleanup for handle: ",
      cast[int](handlePtr)
    cleanup(rm)
    echo "[Nim Binding][Cleanup] Calling GC_unref for handle: ", cast[int](handlePtr)
    GC_unref(rm) # Allow GC to collect the object now that Go is done
    echo "[Nim Binding][Cleanup] GC_unref returned for handle: ", cast[int](handlePtr)
  else:
    echo "[Nim Binding][Cleanup] Warning: CleanupReliabilityManager called with NULL handle"

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
  echo "[Nim Binding][WrapOutgoingMessage] Called with handle=",
    cast[int](handle), " messageLen=", messageLen, " messageId=", $messageIdCStr
  if handle == nil:
    echo "[Nim Binding][WrapOutgoingMessage] Error: handle is nil"
    return
      CWrapResult(base_result: toCResultErrStr("ReliabilityManager handle is NULL"))
  let rm = cast[ReliabilityManager](handle)

  if messageC == nil and messageLen > 0:
    echo "[Nim Binding][WrapOutgoingMessage] Error: message pointer is NULL but length > 0"
    return CWrapResult(
      base_result: toCResultErrStr("Message pointer is NULL but length > 0")
    )
  if messageIdCStr == nil:
    echo "[Nim Binding][WrapOutgoingMessage] Error: messageId pointer is NULL"
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
    echo "[Nim Binding][WrapOutgoingMessage] Returning wrapped message at ",
      cast[int](wrappedDataPtr), " len=", wrappedDataLen
    return CWrapResult(
      base_result: toCResultOk(), message: wrappedDataPtr, message_len: wrappedDataLen
    )
  else:
    echo "[Nim Binding][WrapOutgoingMessage] Error: ", $wrapResult.error
    return CWrapResult(base_result: toCResultErr(wrapResult.error))

proc UnwrapReceivedMessage*(
    handle: CReliabilityManagerHandle, messageC: pointer, messageLen: csize_t
): CUnwrapResult {.exportc, dynlib, cdecl.} =
  echo "[Nim Binding][UnwrapReceivedMessage] Called with handle=",
    cast[int](handle), " messageLen=", messageLen
  if handle == nil:
    echo "[Nim Binding][UnwrapReceivedMessage] Error: handle is nil"
    return
      CUnwrapResult(base_result: toCResultErrStr("ReliabilityManager handle is NULL"))
  let rm = cast[ReliabilityManager](handle)

  if messageC == nil and messageLen > 0:
    echo "[Nim Binding][UnwrapReceivedMessage] Error: message pointer is NULL but length > 0"
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
    echo "[Nim Binding][UnwrapReceivedMessage] Returning content at ",
      cast[int](contentPtr),
      " len=",
      contentLen,
      " missingDepsPtr=",
      cast[int](depsPtr),
      " count=",
      depsCount
    return CUnwrapResult(
      base_result: toCResultOk(),
      message: contentPtr,
      message_len: contentLen,
      missing_deps: depsPtr,
      missing_deps_count: depsCount,
    )
  else:
    echo "[Nim Binding][UnwrapReceivedMessage] Error: ", $unwrapResult.error
    return CUnwrapResult(base_result: toCResultErr(unwrapResult.error))

proc MarkDependenciesMet*(
    handle: CReliabilityManagerHandle, messageIDsC: ptr cstring, count: csize_t
): CResult {.exportc, dynlib, cdecl.} =
  echo "[Nim Binding][MarkDependenciesMet] Called with handle=",
    cast[int](handle), " count=", count
  if handle == nil:
    echo "[Nim Binding][MarkDependenciesMet] Error: handle is nil"
    return toCResultErrStr("ReliabilityManager handle is NULL")
  let rm = cast[ReliabilityManager](handle)

  if messageIDsC == nil and count > 0:
    echo "[Nim Binding][MarkDependenciesMet] Error: messageIDs pointer is NULL but count > 0"
    return toCResultErrStr("MessageIDs pointer is NULL but count > 0")

  var messageIDsNim = newSeq[string](count)
  # Cast to ptr UncheckedArray for indexing
  let messageIDsCArray = cast[ptr UncheckedArray[cstring]](messageIDsC)
  for i in 0 ..< count:
    let currentCStr = messageIDsCArray[i] # Use unchecked array indexing
    if currentCStr != nil:
      messageIDsNim[i] = $currentCStr
      echo "[Nim Binding][MarkDependenciesMet] messageID[",
        i, "] = ", messageIDsNim[i], " at ", cast[int](currentCStr)
    else:
      echo "[Nim Binding][MarkDependenciesMet] NULL message ID found in array at index ",
        i
      return toCResultErrStr("NULL message ID found in array")

  let result = markDependenciesMet(rm, messageIDsNim)
  if result.isOk:
    echo "[Nim Binding][MarkDependenciesMet] Success"
    return toCResultOk()
  else:
    echo "[Nim Binding][MarkDependenciesMet] Error: ", $result.error
    return toCResultErr(result.error)

proc RegisterCallback*(
    handle: CReliabilityManagerHandle,
    cEventCallback: CEventCallback,
    cUserDataPtr: pointer,
) {.exportc, dynlib, cdecl, gcsafe.} =
  if handle == nil:
    echo "[Nim Binding][RegisterCallback] Error: handle is NULL"
    return
  let rm = cast[ReliabilityManager](handle)
  rm.cCallback = cEventCallback
  rm.cUserData = cUserDataPtr # Store user data pointer
  echo "[Nim Binding] Stored C callback and user data for handle: ", cast[int](handle)

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

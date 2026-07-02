## C-compatible FFI wrapper around the SDS ReliabilityManager.
##
## Built on the `nim-ffi` 0.2 package's high-level macros: `declareLibrary`
## emits the bootstrap plus the per-event listener registry
## (`sds_add_event_listener` / `sds_remove_event_listener`);
## `{.ffiCtor.}`/`{.ffi.}`/`{.ffiDtor.}` generate the C entry points,
## marshalling parameters and return values as CBOR; `{.ffiEvent.}` declares
## the library-initiated events (also CBOR). Exported C names are snake_case
## (`sds_wrap_outgoing_message`, …); see `library/libsds.h`. The Go bindings
## (sds-go-bindings) must match this API.
##
## The one exception is `sds_set_retrieval_hint_provider`: it takes a C
## function pointer, which has no sensible CBOR representation, so it is
## hand-written and dispatched to the worker thread (the pointers travel as
## uint64 through the request channel) to store the provider in a thread-local.

import system/ansi_c
import ffi
import sds

# Bootstrap (pragmas, linker flags, libsdsNimMain, initializeLibrary) plus the
# `sds_add_event_listener` / `sds_remove_event_listener` C exports and the
# per-type `ReliabilityManagerFFIPool` used by the hand-written entry point
# below (the ffiCtor/ffiDtor macros declare it too, guarded by `when not
# declared`).
declareLibrary("sds", ReliabilityManager)

type SdsRetrievalHintProvider* = proc(
  messageId: cstring, hint: ptr cstring, hintLen: ptr csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

# The active retrieval-hint provider, stored per worker thread (one thread per
# context). Set by sds_set_retrieval_hint_provider via a dispatched request so
# the write lands on the worker thread, where the manager's hint closure reads
# it during message processing.
var sdsRetrievalHintCb {.threadvar.}: pointer
var sdsRetrievalHintUserData {.threadvar.}: pointer

################################################################################
### CBOR-marshalled request/response types

type SdsConfig* {.ffi.} = object
  participantId: string ## empty disables SDS-R (see newReliabilityManager)

type SdsWrapRequest* {.ffi.} = object
  message: seq[byte]
  messageId: string
  channelId: string

type SdsWrapResponse* {.ffi.} = object
  message: seq[byte]

type SdsUnwrapRequest* {.ffi.} = object
  message: seq[byte]

# One missing dependency: the message id plus an optional retrieval hint. The
# hint is a raw byte string on the CBOR wire (no base64, unlike the old JSON).
type SdsMissingDep* {.ffi.} = object
  messageId: string
  retrievalHint: seq[byte]

type SdsUnwrapResponse* {.ffi.} = object
  message: seq[byte]
  channelId: string
  missingDeps: seq[SdsMissingDep]

type SdsMarkDependenciesRequest* {.ffi.} = object
  messageIds: seq[string]
  channelId: string

################################################################################
### Library-initiated events (CBOR EventEnvelope via {.ffiEvent.})

type SdsMessageReadyEvent* {.ffi.} = object
  messageId: string
  channelId: string

type SdsMessageSentEvent* {.ffi.} = object
  messageId: string
  channelId: string

type SdsMissingDependenciesEvent* {.ffi.} = object
  messageId: string
  missingDeps: seq[SdsMissingDep]
  channelId: string

type SdsPeriodicSyncEvent* {.ffi.} = object
  ok: bool ## carries no data; a field keeps the CBOR map non-degenerate

type SdsRepairReadyEvent* {.ffi.} = object
  message: seq[byte]
  channelId: string

proc onMessageReady*(evt: SdsMessageReadyEvent) {.ffiEvent: "message_ready".}
proc onMessageSent*(evt: SdsMessageSentEvent) {.ffiEvent: "message_sent".}
proc onMissingDependencies*(
  evt: SdsMissingDependenciesEvent
) {.ffiEvent: "missing_dependencies".}

proc onPeriodicSync*(evt: SdsPeriodicSyncEvent) {.ffiEvent: "periodic_sync".}
proc onRepairReady*(evt: SdsRepairReadyEvent) {.ffiEvent: "repair_ready".}

proc toMissingDeps(entries: seq[HistoryEntry]): seq[SdsMissingDep] =
  var deps = newSeq[SdsMissingDep](entries.len)
  for i, entry in entries:
    deps[i] =
      SdsMissingDep(messageId: entry.messageId, retrievalHint: entry.retrievalHint)
  return deps

################################################################################
### Constructor — creates the FFI context and the ReliabilityManager.
###
### The event closures run on the worker thread and forward CBOR payloads to
### the listeners registered via sds_add_event_listener (the {.ffiEvent.} procs
### read the per-thread event queue, so no context handle is needed here).

proc sdsCreate*(
    config: SdsConfig
): Future[Result[ReliabilityManager, string]] {.ffiCtor.} =
  # The ctor body runs on the (possibly recycled) worker thread. Drop any
  # retrieval-hint provider left over from a previous owner of this thread so a
  # stale C function pointer is never invoked.
  sdsRetrievalHintCb = nil
  sdsRetrievalHintUserData = nil

  let rm = newReliabilityManager(
    participantId = config.participantId.SdsParticipantID
  ).valueOr:
    error "Failed creating reliability manager", error = error
    return err("Failed creating reliability manager: " & $error)

  let messageReadyCb = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    onMessageReady(SdsMessageReadyEvent(messageId: messageId, channelId: channelId))

  let messageSentCb = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    onMessageSent(SdsMessageSentEvent(messageId: messageId, channelId: channelId))

  let missingDependenciesCb = proc(
      messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.} =
    onMissingDependencies(
      SdsMissingDependenciesEvent(
        messageId: messageId,
        missingDeps: toMissingDeps(missingDeps),
        channelId: channelId,
      )
    )

  let periodicSyncCb = proc() {.gcsafe.} =
    onPeriodicSync(SdsPeriodicSyncEvent(ok: true))

  let repairReadyCb = proc(message: seq[byte], channelId: SdsChannelID) {.gcsafe.} =
    onRepairReady(SdsRepairReadyEvent(message: message, channelId: channelId))

  let retrievalHintProvider = proc(messageId: SdsMessageID): seq[byte] {.gcsafe.} =
    if sdsRetrievalHintCb.isNil():
      return @[]
    var hint: cstring
    var hintLen: csize_t
    cast[SdsRetrievalHintProvider](sdsRetrievalHintCb)(
      messageId.cstring, addr hint, addr hintLen, sdsRetrievalHintUserData
    )
    if not hint.isNil() and hintLen > 0:
      var hintBytes = newSeq[byte](hintLen)
      copyMem(addr hintBytes[0], hint, hintLen)
      # The provider allocates *hint with libc malloc (Go's C.CBytes); free it
      # with libc free, not Nim's deallocShared, to keep the allocator paired.
      c_free(cast[pointer](hint))
      return hintBytes
    return @[]

  await rm.setCallbacks(
    messageReadyCb, messageSentCb, missingDependenciesCb, periodicSyncCb,
    retrievalHintProvider, repairReadyCb,
  )

  return ok(rm)

################################################################################
### Async methods — each runs its body on the worker thread.

proc sdsWrapOutgoingMessage*(
    rm: ReliabilityManager, req: SdsWrapRequest
): Future[Result[SdsWrapResponse, string]] {.ffi.} =
  let wrapped = (
    await wrapOutgoingMessage(rm, req.message, req.messageId, req.channelId)
  ).valueOr:
    error "WRAP_MESSAGE failed", error = error
    return err("error processing wrap request: " & $error)
  return ok(SdsWrapResponse(message: wrapped))

proc sdsUnwrapReceivedMessage*(
    rm: ReliabilityManager, req: SdsUnwrapRequest
): Future[Result[SdsUnwrapResponse, string]] {.ffi.} =
  let (unwrapped, missingDeps, channelId) = (
    await unwrapReceivedMessage(rm, req.message)
  ).valueOr:
    return err("error processing unwrap request: " & $error)

  return ok(
    SdsUnwrapResponse(
      message: unwrapped, channelId: channelId, missingDeps: toMissingDeps(missingDeps)
    )
  )

proc sdsMarkDependenciesMet*(
    rm: ReliabilityManager, req: SdsMarkDependenciesRequest
): Future[Result[string, string]] {.ffi.} =
  (await markDependenciesMet(rm, req.messageIds, req.channelId)).isOkOr:
    error "MARK_DEPENDENCIES_MET failed", error = error
    return err("error processing mark-dependencies request: " & $error)
  return ok("")

proc sdsReset*(rm: ReliabilityManager): Future[Result[string, string]] {.ffi.} =
  (await resetReliabilityManager(rm)).isOkOr:
    error "RESET failed", error = error
    return err("error processing reset request: " & $error)
  return ok("")

proc sdsStartPeriodicTasks*(
    rm: ReliabilityManager
): Future[Result[string, string]] {.ffi.} =
  # The empty await forces the macro down its async path so the body runs on the
  # worker thread — startPeriodicTasks schedules futures on that thread's loop.
  await sleepAsync(chronos.milliseconds(0))
  rm.startPeriodicTasks()
  return ok("")

################################################################################
### Destructor — runs library cleanup then tears down the FFI context.

proc sdsDestroy*(rm: ReliabilityManager) {.ffiDtor.} =
  discard

################################################################################
### Retrieval-hint provider (hand-written: a C function pointer cannot be passed
### as CBOR). The setter dispatches a request — the provider/userData pointers
### travel as uint64 — so the provider is stored in the worker thread's
### thread-local, where sdsCreate's hint closure reads it.

proc sdsNoopCallback(
    callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

registerReqFFI(SdsSetHintReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(cbPtr: uint64, udPtr: uint64): Future[Result[string, string]] {.async.} =
    sdsRetrievalHintCb = cast[pointer](cbPtr)
    sdsRetrievalHintUserData = cast[pointer](udPtr)
    return ok("")

proc sds_set_retrieval_hint_provider(
    ctx: ptr FFIContext[ReliabilityManager],
    callback: SdsRetrievalHintProvider,
    userData: pointer,
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    return RET_ERR

  let sendRes =
    try:
      ffi_context.sendRequestToFFIThread(
        ctx,
        SdsSetHintReq.ffiNewReq(
          sdsNoopCallback, nil, cast[uint64](cast[pointer](callback)),
          cast[uint64](userData),
        ),
      )
    except Exception as exc:
      Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
  if sendRes.isErr():
    return RET_ERR
  return RET_OK

# Emit binding metadata (no-op unless -d:ffiGenBindings). Must follow every
# {.ffi.}/{.ffiCtor.}/{.ffiDtor.} annotation.
genBindings()

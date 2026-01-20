{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net, locks]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import
  ../ffi_types,
  ./inter_thread_communication/sds_thread_request,
  ../alloc,
  ../../src/[reliability_utils]

type SdsContext* = object
  thread: Thread[(ptr SdsContext)]
  lock: Lock
  reqChannel: ChannelSPSCSingle[ptr SdsThreadRequest]
  reqSignal: ThreadSignalPtr
    # to inform The SDS Thread (a.k.a TST) that a new request is sent
  reqReceivedSignal: ThreadSignalPtr
    # to inform the main thread that the request is rx by TST
  userData*: pointer
  eventCallback*: pointer
  eventUserdata*: pointer
  running: Atomic[bool] # To control when the thread is running
  threadErrorMsg: cstring # to store any error message from the thread

proc runSds(ctx: ptr SdsContext) {.async.} =
  ## This is the worker body. This runs the SDS instance
  ## and attends library user requests (stop, connect_to, etc.)

  var rm: ReliabilityManager

  while true:
    await ctx.reqSignal.wait()

    if ctx.running.load == false:
      break

    ## Trying to get a request from the libsds requestor thread
    var request: ptr SdsThreadRequest
    let recvOk = ctx.reqChannel.tryRecv(request)
    if not recvOk:
      error "sds thread could not receive a request"
      continue

    ## Handle the request
    asyncSpawn SdsThreadRequest.process(request, addr rm)

    let fireRes = ctx.reqReceivedSignal.fireSync()
    if fireRes.isErr():
      error "could not fireSync back to requester thread", error = fireRes.error

proc run(ctx: ptr SdsContext) {.thread.} =
  ## Launch sds worker
  waitFor runSds(ctx)

  ctx.reqSignal.close().isOkOr:
    ctx.threadErrorMsg = alloc("error closing reqSignal: " & $error)
    return

  ctx.reqReceivedSignal.close().isOkOr:
    ctx.threadErrorMsg = alloc("error closing reqReceivedSignal: " & $error)
    return

  shutdown().isOkOr:
    ctx.threadErrorMsg = alloc("error calling shutdown: " & $error)
    return

proc createSdsThread*(): Result[ptr SdsContext, string] =
  ## This proc is called from the main thread and it creates
  ## the SDS working thread.
  var ctx = createShared(SdsContext, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqSignal ThreadSignalPtr")
  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqReceivedSignal ThreadSignalPtr")
  ctx.lock.initLock()

  ctx.running.store(true)

  try:
    createThread(ctx.thread, run, ctx)
  except ValueError, ResourceExhaustedError:
    # and freeShared for typed allocations!
    freeShared(ctx)

    return err("failed to create the SDS thread: " & getCurrentExceptionMsg())

  return ok(ctx)

proc destroySdsThread*(ctx: ptr SdsContext): Result[void, string] =
  ctx.running.store(false)

  let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
    return err("error in destroySdsThread: " & $error)
  if not signaledOnTime:
    return err("failed to signal reqSignal on time in destroySdsThread")

  joinThread(ctx.thread)

  if ctx.threadErrorMsg.len > 0:
    return err("SDS thread error: " & $ctx.threadErrorMsg)

  ctx.lock.deinitLock()
  freeShared(ctx)

  return ok()

proc sendRequestToSdsThread*(
    ctx: ptr SdsContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: SdsCallBack,
    userData: pointer,
): Result[void, string] =
  let req = SdsThreadRequest.createShared(reqType, reqContent, callback, userData)

  # This lock is only necessary while we use a SP Channel and while the signalling
  # between threads assumes that there aren't concurrent requests.
  # Rearchitecting the signaling + migrating to a MP Channel will allow us to receive
  # requests concurrently and spare us the need of locks
  ctx.lock.acquire()
  defer:
    ctx.lock.release()
  ## Sending the request
  let sentOk = ctx.reqChannel.trySend(req)
  if not sentOk:
    deallocShared(req)
    return err("Couldn't send a request to the sds thread: " & $req[])

  let fireSyncRes = ctx.reqSignal.fireSync()
  if fireSyncRes.isErr():
    deallocShared(req)
    return err("failed fireSync: " & $fireSyncRes.error)

  if fireSyncRes.get() == false:
    deallocShared(req)
    return err("Couldn't fireSync in time")

  ## wait until the SDS Thread properly received the request
  let res = ctx.reqReceivedSignal.waitSync()
  if res.isErr():
    deallocShared(req)
    return err("Couldn't receive reqReceivedSignal signal")

  ## Notice that in case of "ok", the deallocShared(req) is performed by the SDS Thread in the
  ## process proc.
  ok()

## This file contains the base message request type that will be handled.
## The requests are created by the main thread and processed by
## the SDS Thread.

import std/json, results
import chronos, chronos/threadsync
import ../../ffi_types, ./requests/sds_lifecycle_request

type RequestType* {.pure.} = enum
  LIFECYCLE

type SdsThreadRequest* = object
  reqType: RequestType
  reqContent: pointer
  callback: SdsCallBack
  userData: pointer

proc createShared*(
    T: type SdsThreadRequest,
    reqType: RequestType,
    reqContent: pointer,
    callback: SdsCallBack,
    userData: pointer,
): ptr type T =
  var ret = createShared(T)
  ret[].reqType = reqType
  ret[].reqContent = reqContent
  ret[].callback = callback
  ret[].userData = userData
  return ret

proc handleRes[T: string | void](
    res: Result[T, string], request: ptr SdsThreadRequest
) =
  ## Handles the Result responses, which can either be Result[string, string] or
  ## Result[void, string].

  defer:
    deallocShared(request)

  if res.isErr():
    foreignThreadGc:
      let msg = "libsds error: handleRes fireSyncRes error: " & $res.error
      request[].callback(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
      )
    return

  foreignThreadGc:
    var msg: cstring = ""
    when T is string:
      msg = res.get().cstring()
    request[].callback(
      RET_OK, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
    )
  return

proc process*(
    T: type SdsThreadRequest, request: ptr SdsThreadRequest, rm: ptr ReliabilityManager
) {.async.} =
  let retFut =
    case request[].reqType
    of LIFECYCLE:
      cast[ptr SdsLifecycleRequest](request[].reqContent).process(rm)

  handleRes(await retFut, request)

proc `$`*(self: SdsThreadRequest): string =
  return $self.reqType

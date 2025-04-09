import std/[options, json, strutils, net]
import chronos, chronicles, results, confutils, confutils/std/net

import ../../../alloc

type SdsLifecycleMsgType* = enum
  CREATE_SDS
  START_SDS
  STOP_SDS

type SdsLifecycleRequest* = object
  operation: SdsLifecycleMsgType
  configJson: cstring ## Only used in 'CREATE_NODE' operation
  appCallbacks: AppCallbacks

proc createShared*(
    T: type SdsLifecycleRequest,
    op: SdsLifecycleMsgType,
    configJson: cstring = "",
    appCallbacks: AppCallbacks = nil,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].appCallbacks = appCallbacks
  ret[].configJson = configJson.alloc()
  return ret

proc destroyShared(self: ptr SdsLifecycleRequest) =
  deallocShared(self[].configJson)
  deallocShared(self)

proc process*(
    self: ptr SdsLifecycleRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_SDS: discard
  of START_SDS: discard
  of STOP_SDS: discard

  return ok("")

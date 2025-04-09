import std/[options, json, strutils, net]
import chronos, chronicles, results, confutils, confutils/std/net

import ../../../alloc

type SdsLifecycleMsgType* = enum
  CREATE_RELIABILITY_MANAGER

type SdsLifecycleRequest* = object
  operation: SdsLifecycleMsgType
  channelId: cstring

proc createShared*(
    T: type SdsLifecycleRequest, op: SdsLifecycleMsgType, configJson: cstring = ""
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].channelId = channelId.alloc()
  return ret

proc destroyShared(self: ptr SdsLifecycleRequest) =
  deallocShared(self[].channelId)
  deallocShared(self)

proc createReliabilityManager(channelId: cstring): Result[ReliabilityManager, string] =
  let channelId = $channelIdCStr
  if channelId.len == 0:
    error "Failed creating ReliabilityManager: Channel ID cannot be empty"
    return err("Failed creating ReliabilityManager: Channel ID cannot be empty")

  let rm = newReliabilityManager(channelId).valueOr:
    error "Failed creating reliability manager", error = error
    return err("Failed creating reliability manager: " & $error)

  rm.onMessageReady = proc(msgId: MessageID) =
    nimMessageReadyCallback(rm, msgId)
  rm.onMessageSent = proc(msgId: MessageID) =
    nimMessageSentCallback(rm, msgId)
  rm.onMissingDependencies = proc(msgId: MessageID, deps: seq[MessageID]) =
    nimMissingDependenciesCallback(rm, msgId, deps)
  rm.onPeriodicSync = proc() =
    nimPeriodicSyncCallback(rm)

  return ok(rm)

proc process*(
    self: ptr SdsLifecycleRequest, rm: ptr ReliabilityManager
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_RELIABILITY_MANAGER:
    rm[] = (await createReliabilityManager(self.channelId)).valueOr:
      error "CREATE_RELIABILITY_MANAGER failed", error = error
      return err("error processing CREATE_RELIABILITY_MANAGER request: " & $error)

  return ok("")

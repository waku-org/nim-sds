import std/[options, json, strutils, net, sequtils]
import chronos, chronicles, results, confutils, confutils/std/net

import ../../../alloc
import ../../../../src/[reliability_utils, reliability, message]

type SdsDependenciesMsgType* = enum
  MARK_DEPENDENCIES_MET

type SdsDependenciesRequest* = object
  operation: SdsDependenciesMsgType
  messageIds: SharedSeq[cstring]
  count: csize_t

proc createShared*(
    T: type SdsDependenciesRequest,
    op: SdsDependenciesMsgType,
    messageIds: SharedSeq[cstring],
    count: csize_t = 0,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].messageIds = messageIds # check if alloc is needed
  ret[].count = count
  return ret

proc destroyShared(self: ptr SdsDependenciesRequest) =
  #deallocShared(self[].message)
  #deallocShared(self[].messageId)
  deallocShared(self)

proc process*(
    self: ptr SdsDependenciesRequest, rm: ptr ReliabilityManager
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of MARK_DEPENDENCIES_MET:
    let messageIdsC = self.messageIds.toSeq()
    let messageIds = messageIdsC.mapIt($it)

    markDependenciesMet(rm[], messageIds).isOkOr:
      error "MARK_DEPENDENCIES_MET failed", error = error
      return err("error processing MARK_DEPENDENCIES_MET request: " & $error)

    return ok("")

  return ok("")

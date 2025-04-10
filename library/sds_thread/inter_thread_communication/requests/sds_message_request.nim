import std/[options, json, strutils, net]
import chronos, chronicles, results, confutils, confutils/std/net

import ../../../alloc
import ../../../../src/[reliability_utils, reliability, message]

type SdsMessageMsgType* = enum
  WRAP_MESSAGE

type SdsMessageRequest* = object
  operation: SdsMessageMsgType
  message: cstring
  messageId: cstring

proc createShared*(
    T: type SdsMessageRequest,
    op: SdsMessageMsgType,
    message: cstring = "",
    messageId: cstring = "",
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].message = message.alloc()
  ret[].messageId = messageId.alloc()
  return ret

proc destroyShared(self: ptr SdsMessageRequest) =
  deallocShared(self[].message)
  deallocShared(self[].messageId)
  deallocShared(self)

proc process*(
    self: ptr SdsMessageRequest, rm: ptr ReliabilityManager
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of WRAP_MESSAGE:
    echo "------- received wrap message request"

  return ok("")

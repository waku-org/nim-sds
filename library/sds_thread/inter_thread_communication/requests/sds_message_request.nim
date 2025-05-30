import std/[options, json, strutils, net, sequtils]
import chronos, chronicles, results, confutils, confutils/std/net

import ../../../alloc
import ../../../../src/[reliability_utils, reliability, message]

type SdsMessageMsgType* = enum
  WRAP_MESSAGE
  UNWRAP_MESSAGE

type SdsMessageRequest* = object
  operation: SdsMessageMsgType
  message: SharedSeq[byte]
  messageLen: csize_t
  messageId: cstring

type SdsUnwrapResponse* = object
  message*: seq[byte]
  missingDeps*: seq[SdsMessageID]

proc createShared*(
    T: type SdsMessageRequest,
    op: SdsMessageMsgType,
    message: pointer,
    messageLen: csize_t = 0,
    messageId: cstring = "",
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].messageLen = messageLen
  ret[].messageId = messageId.alloc()
  ret[].message = allocSharedSeqFromCArray(cast[ptr byte](message), messageLen.int)

  return ret

proc destroyShared(self: ptr SdsMessageRequest) =
  deallocSharedSeq(self[].message)
  deallocShared(self[].messageId)
  deallocShared(self)

proc process*(
    self: ptr SdsMessageRequest, rm: ptr ReliabilityManager
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of WRAP_MESSAGE:
    let messageBytes = self.message.toSeq()

    let wrappedMessage = wrapOutgoingMessage(rm[], messageBytes, $self.messageId).valueOr:
      error "WRAP_MESSAGE failed", error = error
      return err("error processing WRAP_MESSAGE request: " & $error)

    # returns a comma-separates string of bytes
    return ok(wrappedMessage.mapIt($it).join(","))
  of UNWRAP_MESSAGE:
    let messageBytes = self.message.toSeq()

    let (unwrappedMessage, missingDeps) = unwrapReceivedMessage(rm[], messageBytes).valueOr:
      error "UNWRAP_MESSAGE failed", error = error
      return err("error processing UNWRAP_MESSAGE request: " & $error)

    let res = SdsUnwrapResponse(message: unwrappedMessage, missingDeps: missingDeps)

    # return the result as a json string
    return ok($(%*(res)))

  return ok("")

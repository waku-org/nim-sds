import std/[times, hashes, random, sequtils, algorithm, json, options, locks, asyncdispatch]
import chronicles
import "../nim-bloom/src/bloom"
import ./common

proc newRollingBloomFilter*(capacity: int, errorRate: float, window: Duration): Result[RollingBloomFilter] =
  try:
    let filter = initializeBloomFilter(capacity, errorRate)
    return ok(RollingBloomFilter(
      filter: filter,
      window: window,
      messages: @[]
    ))
  except:
    return err[RollingBloomFilter](reInternalError)

proc add*(rbf: var RollingBloomFilter, messageId: MessageID) =
  rbf.filter.insert(messageId)
  rbf.messages.add(TimestampedMessageID(id: messageId, timestamp: getTime()))

proc contains*(rbf: RollingBloomFilter, messageId: MessageID): bool =
  rbf.filter.lookup(messageId)

proc clean*(rbf: var RollingBloomFilter) =
  ## Removes outdated entries from the rolling bloom filter.
  let now = getTime()
  let cutoff = now - rbf.window
  var newMessages: seq[TimestampedMessageID] = @[]
  var newFilter = initializeBloomFilter(rbf.filter.capacity, rbf.filter.errorRate)

  for msg in rbf.messages:
    if msg.timestamp > cutoff:
      newMessages.add(msg)
      newFilter.insert(msg.id)

  rbf.messages = newMessages
  rbf.filter = newFilter

proc cleanBloomFilter*(rm: ReliabilityManager) =
  ## Cleans the rolling bloom filter, removing outdated entries.
  withLock rm.lock:
    rm.bloomFilter.clean()

proc updateLamportTimestamp(rm: ReliabilityManager, msgTs: int64) =
  rm.lamportTimestamp = max(msgTs, rm.lamportTimestamp) + 1

proc getRecentMessageIDs(rm: ReliabilityManager, n: int): seq[MessageID] =
  result = rm.messageHistory[max(0, rm.messageHistory.len - n) .. ^1]

proc generateUniqueID*(): MessageID =
  let timestamp = getTime().toUnix
  let randomPart = rand(high(int))
  result = $hash($timestamp & $randomPart)

proc serializeMessage*(msg: Message): Result[string] =
  try:
    let jsonNode = %*{
      "senderId": msg.senderId,
      "messageId": msg.messageId,
      "lamportTimestamp": msg.lamportTimestamp,
      "causalHistory": msg.causalHistory,
      "channelId": msg.channelId,
      "content": msg.content
    }
    return ok($jsonNode)
  except:
    return err[string](reSerializationError)

proc deserializeMessage*(data: string): Result[Message] =
  try:
    let jsonNode = parseJson(data)
    return ok(Message(
      senderId: jsonNode["senderId"].getStr,
      messageId: jsonNode["messageId"].getStr,
      lamportTimestamp: jsonNode["lamportTimestamp"].getBiggestInt,
      causalHistory: jsonNode["causalHistory"].to(seq[string]),
      channelId: jsonNode["channelId"].getStr,
      content: jsonNode["content"].getStr
    ))
  except:
    return err[Message](reDeserializationError)

proc getMessageHistory*(rm: ReliabilityManager): seq[MessageID] =
  withLock rm.lock:
    return rm.messageHistory

proc getOutgoingBufferSize*(rm: ReliabilityManager): int =
  withLock rm.lock:
    return rm.outgoingBuffer.len

proc getIncomingBufferSize*(rm: ReliabilityManager): int =
  withLock rm.lock:
    return rm.incomingBuffer.len

proc logError*(msg: string) =
  ## Logs an error message
  error "ReliabilityError", message = msg

proc logInfo*(msg: string) =
  ## Logs an informational message
  info "ReliabilityInfo", message = msg

proc checkAndLogError*[T](res: Result[T], errorMsg: string): T =
  if res.isOk:
    return res.value
  else:
    logError(errorMsg & ": " & $res.error)
    raise newException(ValueError, errorMsg)
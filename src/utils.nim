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
  ## Adds a message ID to the rolling bloom filter.
  ##
  ## Parameters:
  ##   - messageId: The ID of the message to add.
  rbf.filter.insert(messageId)
  rbf.messages.add(TimestampedMessageID(id: messageId, timestamp: getTime()))

proc contains*(rbf: RollingBloomFilter, messageId: MessageID): bool =
  ## Checks if a message ID is in the rolling bloom filter.
  ##
  ## Parameters:
  ##   - messageId: The ID of the message to check.
  ##
  ## Returns:
  ##   True if the message ID is probably in the filter, false otherwise.
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
  ## Serializes a Message object to a JSON string.
  ##
  ## Parameters:
  ##   - msg: The Message object to serialize.
  ##
  ## Returns:
  ##   A Result containing either the serialized JSON string or an error.
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
  ## Deserializes a JSON string to a Message object.
  ##
  ## Parameters:
  ##   - data: The JSON string to deserialize.
  ##
  ## Returns:
  ##   A Result containing either the deserialized Message object or an error.
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
  ## Retrieves the current message history from the ReliabilityManager.
  ##
  ## Returns:
  ##   A sequence of MessageIDs representing the current message history.
  withLock rm.lock:
    return rm.messageHistory

proc getOutgoingBufferSize*(rm: ReliabilityManager): int =
  ## Returns the current size of the outgoing message buffer.
  ##
  ## Returns:
  ##   The number of messages in the outgoing buffer.
  withLock rm.lock:
    return rm.outgoingBuffer.len

proc getIncomingBufferSize*(rm: ReliabilityManager): int =
  ## Returns the current size of the incoming message buffer.
  ##
  ## Returns:
  ##   The number of messages in the incoming buffer.
  withLock rm.lock:
    return rm.incomingBuffer.len

proc logError*(msg: string) =
  ## Logs an error message
  error "ReliabilityError", message = msg

proc logInfo*(msg: string) =
  ## Logs an informational message
  info "ReliabilityInfo", message = msg

proc checkAndLogError*[T](res: Result[T], errorMsg: string): T =
  ## Checks the result of an operation, logs any errors, and returns the value or raises an exception.
  ##
  ## Parameters:
  ##   - res: A Result[T] object to check.
  ##   - errorMsg: A message to log if an error occurred.
  ##
  ## Returns:
  ##   The value contained in the Result if it was successful.
  ##
  ## Raises:
  ##   An exception with the error message if the Result contains an error.
  if res.isOk:
    return res.value
  else:
    logError(errorMsg & ": " & $res.error)
    raise newException(ValueError, errorMsg)
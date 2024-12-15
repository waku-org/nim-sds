import std/[times, locks]
import chronos, chronicles
import "../nim-bloom/src/bloom"
import ./common

proc logError*(msg: string) =
  error "ReliabilityError", message = msg

proc logInfo*(msg: string) =
  info "ReliabilityInfo", message = msg

proc newRollingBloomFilter*(capacity: int, errorRate: float, window: times.Duration): RollingBloomFilter {.gcsafe.} =
  try:
    var filter: BloomFilter
    {.gcsafe.}:
      filter = initializeBloomFilter(capacity, errorRate)
    logInfo("Successfully initialized bloom filter")
    RollingBloomFilter(
      filter: filter,
      window: window,
      messages: @[]
    )
  except:
    logError("Failed to initialize bloom filter")
    var filter: BloomFilter
    {.gcsafe.}:
      filter = initializeBloomFilter(DefaultBloomFilterCapacity, DefaultBloomFilterErrorRate)
    RollingBloomFilter(
      filter: filter,
      window: window,
      messages: @[]
    )

proc add*(rbf: var RollingBloomFilter, messageId: MessageID) {.gcsafe.} =
  ## Adds a message ID to the rolling bloom filter.
  ##
  ## Parameters:
  ##   - messageId: The ID of the message to add.
  rbf.filter.insert(messageId)
  rbf.messages.add(TimestampedMessageID(id: messageId, timestamp: getTime()))

proc contains*(rbf: RollingBloomFilter, messageId: MessageID): bool {.gcsafe.} =
  ## Checks if a message ID is in the rolling bloom filter.
  ##
  ## Parameters:
  ##   - messageId: The ID of the message to check.
  ##
  ## Returns:
  ##   True if the message ID is probably in the filter, false otherwise.
  rbf.filter.lookup(messageId)

proc clean*(rbf: var RollingBloomFilter) {.gcsafe.} =
  try:
    let now = getTime()
    let cutoff = now - rbf.window
    var newMessages: seq[TimestampedMessageID] = @[]
    var newFilter: BloomFilter
    {.gcsafe.}:
      newFilter = initializeBloomFilter(rbf.filter.capacity, rbf.filter.errorRate)

    for msg in rbf.messages:
      if msg.timestamp > cutoff:
        newMessages.add(msg)
        newFilter.insert(msg.id)

    rbf.messages = newMessages
    rbf.filter = newFilter
  except Exception as e:
    logError("Failed to clean bloom filter: " & e.msg)

proc cleanBloomFilter*(rm: ReliabilityManager) {.gcsafe, raises: [].} =
  withLock rm.lock:
    try:
      rm.bloomFilter.clean()
    except Exception as e:
      logError("Failed to clean ReliabilityManager bloom filter: " & e.msg)

proc addToHistory*(rm: ReliabilityManager, msgId: MessageID) =
  rm.messageHistory.add(msgId)
  if rm.messageHistory.len > rm.config.maxMessageHistory:
    rm.messageHistory.delete(0)

proc updateLamportTimestamp*(rm: ReliabilityManager, msgTs: int64) =
  rm.lamportTimestamp = max(msgTs, rm.lamportTimestamp) + 1

proc getRecentMessageIDs*(rm: ReliabilityManager, n: int): seq[MessageID] =
  result = rm.messageHistory[max(0, rm.messageHistory.len - n) .. ^1]

proc getMessageHistory*(rm: ReliabilityManager): seq[MessageID] =
  withLock rm.lock:
    result = rm.messageHistory

proc getOutgoingBuffer*(rm: ReliabilityManager): seq[UnacknowledgedMessage] =
  withLock rm.lock:
    result = rm.outgoingBuffer

proc getIncomingBuffer*(rm: ReliabilityManager): seq[Message] =
  withLock rm.lock:
    result = rm.incomingBuffer
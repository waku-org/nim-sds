import std/[times, locks]
import chronicles
import ./[rolling_bloom_filter, message]

type
  PeriodicSyncCallback* = proc() {.gcsafe, raises: [].}

  ReliabilityConfig* = object
    bloomFilterCapacity*: int
    bloomFilterErrorRate*: float
    maxMessageHistory*: int
    maxCausalHistory*: int
    resendInterval*: Duration
    maxResendAttempts*: int
    syncMessageInterval*: Duration
    bufferSweepInterval*: Duration

  ReliabilityManager* = ref object
    lamportTimestamp*: int64
    messageHistory*: seq[MessageID]
    bloomFilter*: RollingBloomFilter
    outgoingBuffer*: seq[UnacknowledgedMessage]
    incomingBuffer*: seq[Message]
    channelId*: ChannelID
    config*: ReliabilityConfig
    lock*: Lock
    onMessageReady*: proc(messageId: MessageID) {.gcsafe.}
    onMessageSent*: proc(messageId: MessageID) {.gcsafe.}
    onMissingDependencies*: proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.}
    onPeriodicSync*: PeriodicSyncCallback

  ReliabilityError* {.pure.} = enum
    reInvalidArgument
    reOutOfMemory
    reInternalError
    reSerializationError
    reDeserializationError
    reMessageTooLarge

proc defaultConfig*(): ReliabilityConfig =
  ## Creates a default configuration for the ReliabilityManager.
  ##
  ## Returns:
  ##   A ReliabilityConfig object with default values.
  ReliabilityConfig(
    bloomFilterCapacity: DefaultBloomFilterCapacity,
    bloomFilterErrorRate: DefaultBloomFilterErrorRate,
    maxMessageHistory: DefaultMaxMessageHistory,
    maxCausalHistory: DefaultMaxCausalHistory,
    resendInterval: DefaultResendInterval,
    maxResendAttempts: DefaultMaxResendAttempts,
    syncMessageInterval: DefaultSyncMessageInterval,
    bufferSweepInterval: DefaultBufferSweepInterval
  )

proc cleanup*(rm: ReliabilityManager) {.raises: [].} =
  if not rm.isNil():
    {.gcsafe.}:
      try:
        withLock rm.lock:
          rm.outgoingBuffer.setLen(0)
          rm.incomingBuffer.setLen(0)
          rm.messageHistory.setLen(0)
      except Exception:
        error "Error during cleanup", msg = getCurrentExceptionMsg()

proc cleanBloomFilter*(rm: ReliabilityManager) {.gcsafe, raises: [].} =
  withLock rm.lock:
    try:
      rm.bloomFilter.clean()
    except Exception:
      error "Failed to clean bloom filter", msg = getCurrentExceptionMsg()

proc addToHistory*(rm: ReliabilityManager, msgId: MessageID) {.gcsafe, raises: [].} =
  rm.messageHistory.add(msgId)
  if rm.messageHistory.len > rm.config.maxMessageHistory:
    rm.messageHistory.delete(0)

proc updateLamportTimestamp*(rm: ReliabilityManager, msgTs: int64) {.gcsafe, raises: [].} =
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
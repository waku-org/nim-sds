import std/[times, locks]
import ./[rolling_bloom_filter, message]

type
  PeriodicSyncCallback* = proc() {.gcsafe, raises: [].}

  ReliabilityConfig* = object
    bloomFilterCapacity*: int
    bloomFilterErrorRate*: float
    bloomFilterWindow*: times.Duration
    maxMessageHistory*: int
    maxCausalHistory*: int
    resendInterval*: times.Duration
    maxResendAttempts*: int
    syncMessageInterval*: times.Duration
    bufferSweepInterval*: times.Duration

  ReliabilityManager* = ref object
    lamportTimestamp*: int64
    messageHistory*: seq[MessageID]
    bloomFilter*: RollingBloomFilter
    outgoingBuffer*: seq[UnacknowledgedMessage]
    incomingBuffer*: seq[Message]
    channelId*: string
    config*: ReliabilityConfig
    lock*: Lock
    onMessageReady*: proc(messageId: MessageID) {.gcsafe.}
    onMessageSent*: proc(messageId: MessageID) {.gcsafe.}
    onMissingDependencies*: proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.}
    onPeriodicSync*: PeriodicSyncCallback

  ReliabilityError* = enum
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
    bloomFilterWindow: DefaultBloomFilterWindow,
    maxMessageHistory: DefaultMaxMessageHistory,
    maxCausalHistory: DefaultMaxCausalHistory,
    resendInterval: DefaultResendInterval,
    maxResendAttempts: DefaultMaxResendAttempts,
    syncMessageInterval: DefaultSyncMessageInterval,
    bufferSweepInterval: DefaultBufferSweepInterval
  )

proc cleanup*(rm: ReliabilityManager) {.raises: [].} =
  if not rm.isNil:
    {.gcsafe.}:
      try:
        rm.outgoingBuffer.setLen(0)
        rm.incomingBuffer.setLen(0)
        rm.messageHistory.setLen(0)
      except Exception as e:
        logError("Error during cleanup: " & e.msg)

proc cleanBloomFilter*(rm: ReliabilityManager) {.gcsafe, raises: [].} =
  withLock rm.lock:
    try:
      rm.bloomFilter.clean()
    except Exception as e:
      logError("Failed to clean ReliabilityManager bloom filter: " & e.msg)

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
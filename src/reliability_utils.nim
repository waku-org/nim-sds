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
    messageHistory*: seq[SdsMessageID]
    bloomFilter*: RollingBloomFilter
    outgoingBuffer*: seq[UnacknowledgedMessage]
    incomingBuffer*: seq[SdsMessage]
    channelId*: SdsChannelID
    config*: ReliabilityConfig
    lock*: Lock
    onMessageReady*: proc(messageId: SdsMessageID) {.gcsafe.}
    onMessageSent*: proc(messageId: SdsMessageID) {.gcsafe.}
    onMissingDependencies*:
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID]) {.gcsafe.}
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
    bufferSweepInterval: DefaultBufferSweepInterval,
  )

proc cleanup*(rm: ReliabilityManager) {.raises: [].} =
  if not rm.isNil():
    try:
      withLock rm.lock:
        rm.outgoingBuffer.setLen(0)
        rm.incomingBuffer.setLen(0)
        rm.messageHistory.setLen(0)
    except Exception:
      error "Error during cleanup", error = getCurrentExceptionMsg()

proc cleanBloomFilter*(rm: ReliabilityManager) {.gcsafe, raises: [].} =
  withLock rm.lock:
    try:
      rm.bloomFilter.clean()
    except Exception:
      error "Failed to clean bloom filter", error = getCurrentExceptionMsg()

proc addToHistory*(rm: ReliabilityManager, msgId: SdsMessageID) {.gcsafe, raises: [].} =
  rm.messageHistory.add(msgId)
  if rm.messageHistory.len > rm.config.maxMessageHistory:
    rm.messageHistory.delete(0)

proc updateLamportTimestamp*(
    rm: ReliabilityManager, msgTs: int64
) {.gcsafe, raises: [].} =
  rm.lamportTimestamp = max(msgTs, rm.lamportTimestamp) + 1

proc getRecentSdsMessageIDs*(rm: ReliabilityManager, n: int): seq[SdsMessageID] =
  result = rm.messageHistory[max(0, rm.messageHistory.len - n) .. ^1]

proc getMessageHistory*(rm: ReliabilityManager): seq[SdsMessageID] =
  withLock rm.lock:
    result = rm.messageHistory

proc getOutgoingBuffer*(rm: ReliabilityManager): seq[UnacknowledgedMessage] =
  withLock rm.lock:
    result = rm.outgoingBuffer

proc getIncomingBuffer*(rm: ReliabilityManager): seq[SdsMessage] =
  withLock rm.lock:
    result = rm.incomingBuffer

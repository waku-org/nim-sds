import std/[times, locks, tables]
import chronicles, results
import ./[rolling_bloom_filter, message]

type
  MessageReadyCallback* =
    proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.}

  MessageSentCallback* =
    proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.}

  MissingDependenciesCallback* = proc(
    messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.}

  RetrievalHintProvider* = proc(messageId: SdsMessageID): seq[byte] {.gcsafe.}

  PeriodicSyncCallback* = proc() {.gcsafe, raises: [].}

  AppCallbacks* = ref object
    messageReadyCb*: MessageReadyCallback
    messageSentCb*: MessageSentCallback
    missingDependenciesCb*: MissingDependenciesCallback
    periodicSyncCb*: PeriodicSyncCallback
    retrievalHintProvider*: RetrievalHintProvider

  ReliabilityConfig* = object
    bloomFilterCapacity*: int
    bloomFilterErrorRate*: float
    maxMessageHistory*: int
    maxCausalHistory*: int
    resendInterval*: Duration
    maxResendAttempts*: int
    syncMessageInterval*: Duration
    bufferSweepInterval*: Duration

  ChannelContext* = ref object
    lamportTimestamp*: int64
    messageHistory*: seq[SdsMessageID]
    bloomFilter*: RollingBloomFilter
    outgoingBuffer*: seq[UnacknowledgedMessage]
    incomingBuffer*: Table[SdsMessageID, IncomingMessage]

  ReliabilityManager* = ref object
    channels*: Table[SdsChannelID, ChannelContext]
    config*: ReliabilityConfig
    lock*: Lock
    onMessageReady*: proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.}
    onMessageSent*: proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.}
    onMissingDependencies*: proc(
      messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
    ) {.gcsafe.}
    onPeriodicSync*: PeriodicSyncCallback
    onRetrievalHint*: RetrievalHintProvider

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
        for channelId, channel in rm.channels:
          channel.outgoingBuffer.setLen(0)
          channel.incomingBuffer.clear()
          channel.messageHistory.setLen(0)
        rm.channels.clear()
    except Exception:
      error "Error during cleanup", error = getCurrentExceptionMsg()

proc cleanBloomFilter*(
    rm: ReliabilityManager, channelId: SdsChannelID
) {.gcsafe, raises: [].} =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        rm.channels[channelId].bloomFilter.clean()
    except Exception:
      error "Failed to clean bloom filter",
        error = getCurrentExceptionMsg(), channelId = channelId

proc addToHistory*(
    rm: ReliabilityManager, msgId: SdsMessageID, channelId: SdsChannelID
) {.gcsafe, raises: [].} =
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      channel.messageHistory.add(msgId)
      if channel.messageHistory.len > rm.config.maxMessageHistory:
        channel.messageHistory.delete(0)
  except Exception:
    error "Failed to add to history",
      channelId = channelId, msgId = msgId, error = getCurrentExceptionMsg()

proc updateLamportTimestamp*(
    rm: ReliabilityManager, msgTs: int64, channelId: SdsChannelID
) {.gcsafe, raises: [].} =
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      channel.lamportTimestamp = max(msgTs, channel.lamportTimestamp) + 1
  except Exception:
    error "Failed to update lamport timestamp",
      channelId = channelId, msgTs = msgTs, error = getCurrentExceptionMsg()

proc getRecentHistoryEntries*(
    rm: ReliabilityManager, n: int, channelId: SdsChannelID
): seq[HistoryEntry] =
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      let recentMessageIds = channel.messageHistory[max(0, channel.messageHistory.len - n) .. ^1]
      if rm.onRetrievalHint.isNil():
        return toCausalHistory(recentMessageIds)
      else:
        for msgId in recentMessageIds:
          let hint = rm.onRetrievalHint(msgId)
          result.add(newHistoryEntry(msgId, hint))
    else:
      result = @[]
  except Exception:
    error "Failed to get recent history entries",
      channelId = channelId, n = n, error = getCurrentExceptionMsg()
    result = @[]

proc checkDependencies*(
    rm: ReliabilityManager, deps: seq[HistoryEntry], channelId: SdsChannelID
): seq[HistoryEntry] =
  var missingDeps: seq[HistoryEntry] = @[]
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      for dep in deps:
        if dep.messageId notin channel.messageHistory:
          # If we have a retrieval hint provider and the original dep has no hint, get one
          if not rm.onRetrievalHint.isNil() and dep.retrievalHint.len == 0:
            let hint = rm.onRetrievalHint(dep.messageId)
            missingDeps.add(newHistoryEntry(dep.messageId, hint))
          else:
            missingDeps.add(dep)
    else:
      # Channel doesn't exist, all deps are missing
      if not rm.onRetrievalHint.isNil():
        for dep in deps:
          if dep.retrievalHint.len == 0:
            let hint = rm.onRetrievalHint(dep.messageId)
            missingDeps.add(newHistoryEntry(dep.messageId, hint))
          else:
            missingDeps.add(dep)
      else:
        missingDeps = deps
  except Exception:
    error "Failed to check dependencies",
      channelId = channelId, error = getCurrentExceptionMsg()
    missingDeps = deps
  return missingDeps

proc getMessageHistory*(
    rm: ReliabilityManager, channelId: SdsChannelID
): seq[SdsMessageID] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        result = rm.channels[channelId].messageHistory
      else:
        result = @[]
    except Exception:
      error "Failed to get message history",
        channelId = channelId, error = getCurrentExceptionMsg()
      result = @[]

proc getOutgoingBuffer*(
    rm: ReliabilityManager, channelId: SdsChannelID
): seq[UnacknowledgedMessage] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        result = rm.channels[channelId].outgoingBuffer
      else:
        result = @[]
    except Exception:
      error "Failed to get outgoing buffer",
        channelId = channelId, error = getCurrentExceptionMsg()
      result = @[]

proc getIncomingBuffer*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Table[SdsMessageID, message.IncomingMessage] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        result = rm.channels[channelId].incomingBuffer
      else:
        result = initTable[SdsMessageID, message.IncomingMessage]()
    except Exception:
      error "Failed to get incoming buffer",
        channelId = channelId, error = getCurrentExceptionMsg()
      result = initTable[SdsMessageID, message.IncomingMessage]()

proc getOrCreateChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): ChannelContext =
  try:
    if channelId notin rm.channels:
      rm.channels[channelId] = ChannelContext(
        lamportTimestamp: 0,
        messageHistory: @[],
        bloomFilter: newRollingBloomFilter(
          rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate
        ),
        outgoingBuffer: @[],
        incomingBuffer: initTable[SdsMessageID, IncomingMessage](),
      )
    result = rm.channels[channelId]
  except Exception:
    error "Failed to get or create channel",
      channelId = channelId, error = getCurrentExceptionMsg()
    raise

proc ensureChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Result[void, ReliabilityError] =
  withLock rm.lock:
    try:
      discard rm.getOrCreateChannel(channelId)
      return ok()
    except Exception:
      error "Failed to ensure channel",
        channelId = channelId, msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reInternalError)

proc removeChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Result[void, ReliabilityError] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        let channel = rm.channels[channelId]
        channel.outgoingBuffer.setLen(0)
        channel.incomingBuffer.clear()
        channel.messageHistory.setLen(0)
        rm.channels.del(channelId)
      return ok()
    except Exception:
      error "Failed to remove channel",
        channelId = channelId, msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reInternalError)

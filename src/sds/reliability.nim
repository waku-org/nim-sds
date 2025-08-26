import std/[times, locks, tables, sets, options]
import chronos, results, chronicles
import ./[message, protobuf, reliability_utils, rolling_bloom_filter]

export message, reliability_utils, protobuf

proc newReliabilityManager*(
    config: ReliabilityConfig = defaultConfig()
): Result[ReliabilityManager, ReliabilityError] =
  ## Creates a new multi-channel ReliabilityManager.
  ##
  ## Parameters:
  ##   - config: Configuration options for the ReliabilityManager. If not provided, default configuration is used.
  ##
  ## Returns:
  ##   A Result containing either a new ReliabilityManager instance or an error.
  try:
    let rm = ReliabilityManager(
      channels: initTable[SdsChannelID, ChannelContext](), config: config
    )
    initLock(rm.lock)
    return ok(rm)
  except Exception:
    error "Failed to create ReliabilityManager", msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reOutOfMemory)

proc isAcknowledged*(
    msg: UnacknowledgedMessage,
    causalHistory: seq[SdsMessageID],
    rbf: Option[RollingBloomFilter],
): bool =
  if msg.message.messageId in causalHistory:
    return true

  if rbf.isSome():
    return rbf.get().contains(msg.message.messageId)

  false

proc reviewAckStatus(rm: ReliabilityManager, msg: SdsMessage) {.gcsafe.} =
  # Parse bloom filter
  var rbf: Option[RollingBloomFilter]
  if msg.bloomFilter.len > 0:
    let bfResult = deserializeBloomFilter(msg.bloomFilter)
    if bfResult.isOk():
      rbf = some(
        RollingBloomFilter(
          filter: bfResult.get(),
          capacity: bfResult.get().capacity,
          minCapacity: (
            bfResult.get().capacity.float * (100 - CapacityFlexPercent).float / 100.0
        ).int,
        maxCapacity: (
          bfResult.get().capacity.float * (100 + CapacityFlexPercent).float / 100.0
        ).int,
        messages: @[],
      )
      )
    else:
      error "Failed to deserialize bloom filter", error = bfResult.error
      rbf = none[RollingBloomFilter]()
  else:
    rbf = none[RollingBloomFilter]()

  if msg.channelId notin rm.channels:
    return

  let channel = rm.channels[msg.channelId]
  # Keep track of indices to delete
  var toDelete: seq[int] = @[]
  var i = 0

  while i < channel.outgoingBuffer.len:
    let outMsg = channel.outgoingBuffer[i]
    if outMsg.isAcknowledged(msg.causalHistory, rbf):
      if not rm.onMessageSent.isNil():
        rm.onMessageSent(outMsg.message.messageId, outMsg.message.channelId)
      toDelete.add(i)
    inc i

  for i in countdown(toDelete.high, 0): # Delete in reverse order to maintain indices
    channel.outgoingBuffer.delete(toDelete[i])

proc wrapOutgoingMessage*(
    rm: ReliabilityManager,
    message: seq[byte],
    messageId: SdsMessageID,
    channelId: SdsChannelID,
): Result[seq[byte], ReliabilityError] =
  ## Wraps an outgoing message with reliability metadata.
  ##
  ## Parameters:
  ##   - message: The content of the message to be sent.
  ##   - messageId: Unique identifier for the message
  ##   - channelId: Identifier for the channel this message belongs to.
  ##
  ## Returns:
  ##   A Result containing either wrapped message bytes or an error.
  if message.len == 0:
    return err(ReliabilityError.reInvalidArgument)
  if message.len > MaxMessageSize:
    return err(ReliabilityError.reMessageTooLarge)

  withLock rm.lock:
    try:
      let channel = rm.getOrCreateChannel(channelId)
      rm.updateLamportTimestamp(getTime().toUnix, channelId)

      let bfResult = serializeBloomFilter(channel.bloomFilter.filter)
      if bfResult.isErr:
        error "Failed to serialize bloom filter", channelId = channelId
        return err(ReliabilityError.reSerializationError)

      let msg = SdsMessage(
        messageId: messageId,
        lamportTimestamp: channel.lamportTimestamp,
        causalHistory: rm.getRecentSdsMessageIDs(rm.config.maxCausalHistory,
            channelId),
        channelId: channelId,
        content: message,
        bloomFilter: bfResult.get(),
      )

      channel.outgoingBuffer.add(
        UnacknowledgedMessage(message: msg, sendTime: getTime(),
            resendAttempts: 0)
      )

      # Add to causal history and bloom filter
      channel.bloomFilter.add(msg.messageId)
      rm.addToHistory(msg.messageId, channelId)

      return serializeMessage(msg)
    except Exception:
      error "Failed to wrap message",
        channelId = channelId, msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reSerializationError)

proc processIncomingBuffer(rm: ReliabilityManager,
    channelId: SdsChannelID) {.gcsafe.} =
  withLock rm.lock:
    if channelId notin rm.channels:
      error "Channel does not exist", channelId = channelId
      return

    let channel = rm.channels[channelId]
    if channel.incomingBuffer.len == 0:
      return

    var processed = initHashSet[SdsMessageID]()
    var readyToProcess = newSeq[SdsMessageID]()

    # Find initially ready messages
    for msgId, entry in channel.incomingBuffer:
      if entry.missingDeps.len == 0:
        readyToProcess.add(msgId)

    while readyToProcess.len > 0:
      let msgId = readyToProcess.pop()
      if msgId in processed:
        continue

      if msgId in channel.incomingBuffer:
        rm.addToHistory(msgId, channelId)
        if not rm.onMessageReady.isNil():
          rm.onMessageReady(msgId, channelId)
        processed.incl(msgId)

        # Update dependencies for remaining messages
        for remainingId, entry in channel.incomingBuffer:
          if remainingId notin processed:
            if msgId in entry.missingDeps:
              channel.incomingBuffer[remainingId].missingDeps.excl(msgId)
              if channel.incomingBuffer[remainingId].missingDeps.len == 0:
                readyToProcess.add(remainingId)

    # Remove processed messages
    for msgId in processed:
      channel.incomingBuffer.del(msgId)

proc unwrapReceivedMessage*(
    rm: ReliabilityManager, message: seq[byte]
): Result[
    tuple[message: seq[byte], missingDeps: seq[SdsMessageID],
        channelId: SdsChannelID],
    ReliabilityError,
] =
  ## Unwraps a received message and processes its reliability metadata.
  ##
  ## Parameters:
  ##   - message: The received message bytes
  ##
  ## Returns:
  ##   A Result containing either tuple of (processed message, missing dependencies, channel ID) or an error.
  try:
    let channelId = extractChannelId(message).valueOr:
      return err(ReliabilityError.reDeserializationError)

    let msg = deserializeMessage(message).valueOr:
      return err(ReliabilityError.reDeserializationError)

    let channel = rm.getOrCreateChannel(channelId)

    if msg.messageId in channel.messageHistory:
      return ok((msg.content, @[], channelId))

    channel.bloomFilter.add(msg.messageId)

    rm.updateLamportTimestamp(msg.lamportTimestamp, channelId)
    # Review ACK status for outgoing messages
    rm.reviewAckStatus(msg)

    var missingDeps = rm.checkDependencies(msg.causalHistory, channelId)

    if missingDeps.len == 0:
      var depsInBuffer = false
      for msgId, entry in channel.incomingBuffer.pairs():
        if msgId in msg.causalHistory:
          depsInBuffer = true
          break
      # Check if any dependencies are still in incoming buffer
      if depsInBuffer:
        channel.incomingBuffer[msg.messageId] =
          IncomingMessage(message: msg, missingDeps: initHashSet[SdsMessageID]())
      else:
        # All dependencies met, add to history
        rm.addToHistory(msg.messageId, channelId)
        rm.processIncomingBuffer(channelId)
        if not rm.onMessageReady.isNil():
          rm.onMessageReady(msg.messageId, channelId)
    else:
      channel.incomingBuffer[msg.messageId] =
        IncomingMessage(message: msg, missingDeps: missingDeps.toHashSet())
      if not rm.onMissingDependencies.isNil():
        rm.onMissingDependencies(msg.messageId, missingDeps, channelId)

    return ok((msg.content, missingDeps, channelId))
  except Exception:
    error "Failed to unwrap message", msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reDeserializationError)

proc markDependenciesMet*(
    rm: ReliabilityManager, messageIds: seq[SdsMessageID],
        channelId: SdsChannelID
): Result[void, ReliabilityError] =
  ## Marks the specified message dependencies as met.
  ##
  ## Parameters:
  ##   - messageIds: A sequence of message IDs to mark as met.
  ##   - channelId: Identifier for the channel.
  ##
  ## Returns:
  ##   A Result indicating success or an error.
  try:
    if channelId notin rm.channels:
      return err(ReliabilityError.reInvalidArgument)

    let channel = rm.channels[channelId]

    for msgId in messageIds:
      if not channel.bloomFilter.contains(msgId):
        channel.bloomFilter.add(msgId)

      for pendingId, entry in channel.incomingBuffer:
        if msgId in entry.missingDeps:
          channel.incomingBuffer[pendingId].missingDeps.excl(msgId)

    rm.processIncomingBuffer(channelId)
    return ok()
  except Exception:
    error "Failed to mark dependencies as met",
      channelId = channelId, msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reInternalError)

proc setCallbacks*(
    rm: ReliabilityManager,
    onMessageReady: MessageReadyCallback,
    onMessageSent: MessageSentCallback,
    onMissingDependencies: MissingDependenciesCallback,
    onPeriodicSync: PeriodicSyncCallback = nil,
) =
  ## Sets the callback functions for various events in the ReliabilityManager.
  ##
  ## Parameters:
  ##   - onMessageReady: Callback function called when a message is ready to be processed.
  ##   - onMessageSent: Callback function called when a message is confirmed as sent.
  ##   - onMissingDependencies: Callback function called when a message has missing dependencies.
  ##   - onPeriodicSync: Callback function called to notify about periodic sync
  withLock rm.lock:
    rm.onMessageReady = onMessageReady
    rm.onMessageSent = onMessageSent
    rm.onMissingDependencies = onMissingDependencies
    rm.onPeriodicSync = onPeriodicSync

proc checkUnacknowledgedMessages(
    rm: ReliabilityManager, channelId: SdsChannelID
) {.gcsafe.} =
  ## Checks and processes unacknowledged messages in the outgoing buffer.
  withLock rm.lock:
    if channelId notin rm.channels:
      error "Channel does not exist", channelId = channelId
      return

    let channel = rm.channels[channelId]
    let now = getTime()
    var newOutgoingBuffer: seq[UnacknowledgedMessage] = @[]

    for unackMsg in channel.outgoingBuffer:
      let elapsed = now - unackMsg.sendTime
      if elapsed > rm.config.resendInterval:
        if unackMsg.resendAttempts < rm.config.maxResendAttempts:
          var updatedMsg = unackMsg
          updatedMsg.resendAttempts += 1
          updatedMsg.sendTime = now
          newOutgoingBuffer.add(updatedMsg)
        else:
          if not rm.onMessageSent.isNil():
            rm.onMessageSent(unackMsg.message.messageId, channelId)
      else:
        newOutgoingBuffer.add(unackMsg)

    channel.outgoingBuffer = newOutgoingBuffer

proc periodicBufferSweep(
    rm: ReliabilityManager
) {.async: (raises: [CancelledError]), gcsafe.} =
  ## Periodically sweeps the buffer to clean up and check unacknowledged messages.
  while true:
    try:
      for channelId, channel in rm.channels:
        try:
          rm.checkUnacknowledgedMessages(channelId)
          rm.cleanBloomFilter(channelId)
        except Exception:
          error "Error in buffer sweep for channel",
            channelId = channelId, msg = getCurrentExceptionMsg()
    except Exception:
      error "Error in periodic buffer sweep", msg = getCurrentExceptionMsg()

    await sleepAsync(chronos.milliseconds(
        rm.config.bufferSweepInterval.inMilliseconds))

proc periodicSyncMessage(
    rm: ReliabilityManager
) {.async: (raises: [CancelledError]), gcsafe.} =
  ## Periodically notifies to send a sync message to maintain connectivity.
  while true:
    try:
      if not rm.onPeriodicSync.isNil():
        rm.onPeriodicSync()
    except Exception:
      error "Error in periodic sync", msg = getCurrentExceptionMsg()
    await sleepAsync(chronos.seconds(rm.config.syncMessageInterval.inSeconds))

proc startPeriodicTasks*(rm: ReliabilityManager) =
  ## Starts the periodic tasks for buffer sweeping and sync message sending.
  ##
  ## This procedure should be called after creating a ReliabilityManager to enable automatic maintenance.
  asyncSpawn rm.periodicBufferSweep()
  asyncSpawn rm.periodicSyncMessage()

proc resetReliabilityManager*(rm: ReliabilityManager): Result[void,
    ReliabilityError] =
  ## Resets the ReliabilityManager to its initial state.
  ##
  ## This procedure clears all buffers and resets the Lamport timestamp.
  withLock rm.lock:
    try:
      for channelId, channel in rm.channels:
        channel.lamportTimestamp = 0
        channel.messageHistory.setLen(0)
        channel.outgoingBuffer.setLen(0)
        channel.incomingBuffer.clear()
        channel.bloomFilter = newRollingBloomFilter(
          rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate
        )
      rm.channels.clear()
      return ok()
    except Exception:
      error "Failed to reset ReliabilityManager", msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reInternalError)

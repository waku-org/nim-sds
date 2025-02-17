import std/[times, locks, tables, sets, sequtils]
import chronos, results, chronicles
import ./[message, protobuf, reliability_utils, rolling_bloom_filter]

proc newReliabilityManager*(
    channelId: SdsChannelID, config: ReliabilityConfig = defaultConfig()
): Result[ReliabilityManager, ReliabilityError] =
  ## Creates a new ReliabilityManager with the specified channel ID and configuration.
  ##
  ## Parameters:
  ##   - channelId: A unique identifier for the communication channel.
  ##   - config: Configuration options for the ReliabilityManager. If not provided, default configuration is used.
  ##
  ## Returns:
  ##   A Result containing either a new ReliabilityManager instance or an error.
  if channelId.len == 0:
    return err(ReliabilityError.reInvalidArgument)

  try:
    let bloomFilter =
      newRollingBloomFilter(config.bloomFilterCapacity, config.bloomFilterErrorRate)

    let rm = ReliabilityManager(
      lamportTimestamp: 0,
      messageHistory: @[],
      bloomFilter: bloomFilter,
      outgoingBuffer: @[],
      incomingBuffer: @[],
      channelId: channelId,
      config: config,
    )
    initLock(rm.lock)
    return ok(rm)
  except Exception:
    error "Failed to create ReliabilityManager", msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reOutOfMemory)

proc reviewAckStatus(rm: ReliabilityManager, msg: SdsMessage) {.gcsafe.} =
  var i = 0
  while i < rm.outgoingBuffer.len:
    var acknowledged = false
    let outMsg = rm.outgoingBuffer[i]

    # Check if message is in causal history
    for msgID in msg.causalHistory:
      if outMsg.message.messageId == msgID:
        acknowledged = true
        break

    # Check bloom filter if not already acknowledged
    if not acknowledged and msg.bloomFilter.len > 0:
      let bfResult = deserializeBloomFilter(msg.bloomFilter)
      if bfResult.isOk():
        var rbf = RollingBloomFilter(
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
        if rbf.contains(outMsg.message.messageId):
          acknowledged = true
      else:
        error "Failed to deserialize bloom filter", error = bfResult.error

    if acknowledged:
      if not rm.onMessageSent.isNil():
        rm.onMessageSent(outMsg.message.messageId)
      rm.outgoingBuffer.delete(i)
    else:
      inc i

proc wrapOutgoingMessage*(
    rm: ReliabilityManager, message: seq[byte], messageId: SdsMessageID
): Result[seq[byte], ReliabilityError] =
  ## Wraps an outgoing message with reliability metadata.
  ##
  ## Parameters:
  ##   - message: The content of the message to be sent.
  ##   - messageId: Unique identifier for the message
  ##
  ## Returns:
  ##   A Result containing either wrapped message bytes or an error.
  if message.len == 0:
    return err(ReliabilityError.reInvalidArgument)
  if message.len > MaxMessageSize:
    return err(ReliabilityError.reMessageTooLarge)

  withLock rm.lock:
    try:
      rm.updateLamportTimestamp(getTime().toUnix)

      let bfResult = serializeBloomFilter(rm.bloomFilter.filter)
      if bfResult.isErr:
        error "Failed to serialize bloom filter"
        return err(ReliabilityError.reSerializationError)

      let msg = SdsMessage(
        messageId: messageId,
        lamportTimestamp: rm.lamportTimestamp,
        causalHistory: rm.getRecentSdsMessageIDs(rm.config.maxCausalHistory),
        channelId: rm.channelId,
        content: message,
        bloomFilter: bfResult.get(),
      )

      # Add to outgoing buffer
      rm.outgoingBuffer.add(
        UnacknowledgedMessage(message: msg, sendTime: getTime(), resendAttempts: 0)
      )

      # Add to causal history and bloom filter
      rm.bloomFilter.add(msg.messageId)
      rm.addToHistory(msg.messageId)

      return serializeMessage(msg)
    except Exception:
      error "Failed to wrap message", msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reSerializationError)

proc processIncomingBuffer(rm: ReliabilityManager) {.gcsafe.} =
  withLock rm.lock:
    if rm.incomingBuffer.len == 0:
      return

    # Create dependency map
    var dependencies = initTable[SdsMessageID, seq[SdsMessageID]]()
    var readyToProcess: seq[SdsMessageID] = @[]
    var processed = initHashSet[SdsMessageID]()

    # Build dependency graph and find initially ready messages
    for msg in rm.incomingBuffer:
      var hasMissingDeps = false
      for depId in msg.causalHistory:
        if not rm.bloomFilter.contains(depId):
          hasMissingDeps = true
          if depId notin dependencies:
            dependencies[depId] = @[]
          dependencies[depId].add(msg.messageId)

      if not hasMissingDeps:
        readyToProcess.add(msg.messageId)

    while readyToProcess.len > 0:
      let msgId = readyToProcess.pop()
      if msgId in processed:
        continue

      # Process this message
      for msg in rm.incomingBuffer:
        if msg.messageId == msgId:
          rm.addToHistory(msg.messageId)
          if not rm.onMessageReady.isNil():
            rm.onMessageReady(msg.messageId)
          processed.incl(msgId)

          # Add any dependent messages that might now be ready
          if msgId in dependencies:
            readyToProcess.add(dependencies[msgId])
          break

    rm.incomingBuffer = rm.incomingBuffer.filterIt(it.messageId notin processed)

proc unwrapReceivedMessage*(
    rm: ReliabilityManager, message: seq[byte]
): Result[tuple[message: seq[byte], missingDeps: seq[SdsMessageID]], ReliabilityError] =
  ## Unwraps a received message and processes its reliability metadata.
  ##
  ## Parameters:
  ##   - message: The received message bytes
  ##
  ## Returns:
  ##   A Result containing either tuple of (processed message, missing dependencies) or an error.
  try:
    let msg = deserializeMessage(message).valueOr:
      return err(ReliabilityError.reDeserializationError)

    if rm.bloomFilter.contains(msg.messageId):
      return ok((msg.content, @[]))

    rm.bloomFilter.add(msg.messageId)

    # Update Lamport timestamp
    rm.updateLamportTimestamp(msg.lamportTimestamp)

    # Review ACK status for outgoing messages
    rm.reviewAckStatus(msg)

    var missingDeps: seq[SdsMessageID] = @[]
    for depId in msg.causalHistory:
      if not rm.bloomFilter.contains(depId):
        missingDeps.add(depId)

    if missingDeps.len == 0:
      # Check if any dependencies are still in incoming buffer
      var depsInBuffer = false
      for bufferedMsg in rm.incomingBuffer:
        if bufferedMsg.messageId in msg.causalHistory:
          depsInBuffer = true
          break

      if depsInBuffer:
        rm.incomingBuffer.add(msg)
      else:
        # All dependencies met, add to history
        rm.addToHistory(msg.messageId)
        rm.processIncomingBuffer()
        if not rm.onMessageReady.isNil():
          rm.onMessageReady(msg.messageId)
    else:
      rm.incomingBuffer.add(msg)
      if not rm.onMissingDependencies.isNil():
        rm.onMissingDependencies(msg.messageId, missingDeps)

    return ok((msg.content, missingDeps))
  except Exception:
    error "Failed to unwrap message", msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reDeserializationError)

proc markDependenciesMet*(
    rm: ReliabilityManager, messageIds: seq[SdsMessageID]
): Result[void, ReliabilityError] =
  ## Marks the specified message dependencies as met.
  ##
  ## Parameters:
  ##   - messageIds: A sequence of message IDs to mark as met.
  ##
  ## Returns:
  ##   A Result indicating success or an error.
  try:
    # Add all messageIds to bloom filter
    for msgId in messageIds:
      if not rm.bloomFilter.contains(msgId):
        rm.bloomFilter.add(msgId)
        # rm.addToHistory(msgId) -- not needed as this proc usually called when msg in long-term storage of application?

    rm.processIncomingBuffer()
    return ok()
  except Exception:
    error "Failed to mark dependencies as met", msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reInternalError)

proc setCallbacks*(
    rm: ReliabilityManager,
    onMessageReady: proc(messageId: SdsMessageID) {.gcsafe.},
    onMessageSent: proc(messageId: SdsMessageID) {.gcsafe.},
    onMissingDependencies:
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID]) {.gcsafe.},
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

proc checkUnacknowledgedMessages(rm: ReliabilityManager) {.gcsafe.} =
  ## Checks and processes unacknowledged messages in the outgoing buffer.
  withLock rm.lock:
    let now = getTime()
    var newOutgoingBuffer: seq[UnacknowledgedMessage] = @[]

    for unackMsg in rm.outgoingBuffer:
      let elapsed = now - unackMsg.sendTime
      if elapsed > rm.config.resendInterval:
        # Time to attempt resend
        if unackMsg.resendAttempts < rm.config.maxResendAttempts:
          var updatedMsg = unackMsg
          updatedMsg.resendAttempts += 1
          updatedMsg.sendTime = now
          newOutgoingBuffer.add(updatedMsg)
        else:
          if not rm.onMessageSent.isNil():
            rm.onMessageSent(unackMsg.message.messageId)
      else:
        newOutgoingBuffer.add(unackMsg)

    rm.outgoingBuffer = newOutgoingBuffer

proc periodicBufferSweep(
    rm: ReliabilityManager
) {.async: (raises: [CancelledError]), gcsafe.} =
  ## Periodically sweeps the buffer to clean up and check unacknowledged messages.
  while true:
    try:
      rm.checkUnacknowledgedMessages()
      rm.cleanBloomFilter()
    except Exception:
      error "Error in periodic buffer sweep", msg = getCurrentExceptionMsg()

    await sleepAsync(chronos.milliseconds(rm.config.bufferSweepInterval.inMilliseconds))

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

proc resetReliabilityManager*(rm: ReliabilityManager): Result[void, ReliabilityError] =
  ## Resets the ReliabilityManager to its initial state.
  ##
  ## This procedure clears all buffers and resets the Lamport timestamp.
  withLock rm.lock:
    try:
      rm.lamportTimestamp = 0
      rm.messageHistory.setLen(0)
      rm.outgoingBuffer.setLen(0)
      rm.incomingBuffer.setLen(0)
      rm.bloomFilter = newRollingBloomFilter(
        rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate
      )
      return ok()
    except Exception:
      error "Failed to reset ReliabilityManager", msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reInternalError)

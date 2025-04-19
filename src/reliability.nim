import std/[times, locks, tables, sets]
import chronos, results
import ../src/[message, protobuf, reliability_utils, rolling_bloom_filter]

proc newReliabilityManager*(
    channelId: string, config: ReliabilityConfig = defaultConfig()
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
    return err(reInvalidArgument)

  try:
    let bloomFilter = newRollingBloomFilter(
      config.bloomFilterCapacity, config.bloomFilterErrorRate, config.bloomFilterWindow
    )

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
  except:
    return err(reOutOfMemory)

proc reviewAckStatus(rm: ReliabilityManager, msg: Message) =
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
      if bfResult.isOk:
        var rbf = RollingBloomFilter(
          filter: bfResult.get(), window: rm.bloomFilter.window, messages: @[]
        )
        if rbf.contains(outMsg.message.messageId):
          acknowledged = true
      else:
        logError("Failed to deserialize bloom filter")

    if acknowledged:
      echo "[Nim Core] reviewAckStatus: Message acknowledged: ",
        outMsg.message.messageId
      if rm.onMessageSent != nil:
        echo "[Nim Core] reviewAckStatus: Calling onMessageSent for: ",
          outMsg.message.messageId
        rm.onMessageSent(rm, outMsg.message.messageId) # Pass rm
      else:
        echo "[Nim Core] reviewAckStatus: rm.onMessageSent is nil, cannot call callback for: ",
          outMsg.message.messageId
      rm.outgoingBuffer.delete(i)
    else:
      inc i

proc wrapOutgoingMessage*(
    rm: ReliabilityManager, message: seq[byte], messageId: MessageID
): Result[seq[byte], ReliabilityError] =
  ## Wraps an outgoing message with reliability metadata.
  ##
  ## Parameters:
  ##   - message: The content of the message to be sent.
  ##
  ## Returns:
  ##   A Result containing either a Message object with reliability metadata or an error.
  if message.len == 0:
    return err(reInvalidArgument)
  if message.len > MaxMessageSize:
    return err(reMessageTooLarge)

  withLock rm.lock:
    try:
      rm.updateLamportTimestamp(getTime().toUnix)

      # Serialize current bloom filter
      var bloomBytes: seq[byte]
      let bfResult = serializeBloomFilter(rm.bloomFilter.filter)
      if bfResult.isErr:
        logError("Failed to serialize bloom filter")
        bloomBytes = @[]
      else:
        bloomBytes = bfResult.get()

      let msg = Message(
        messageId: messageId,
        lamportTimestamp: rm.lamportTimestamp,
        causalHistory: rm.getRecentMessageIDs(rm.config.maxCausalHistory),
        channelId: rm.channelId,
        content: message,
        bloomFilter: bloomBytes,
      )

      # Add to outgoing buffer
      rm.outgoingBuffer.add(
        UnacknowledgedMessage(message: msg, sendTime: getTime(), resendAttempts: 0)
      )

      # Add to causal history and bloom filter
      rm.bloomFilter.add(msg.messageId)
      rm.addToHistory(msg.messageId)

      return serializeMessage(msg)
    except:
      return err(reInternalError)

proc processIncomingBuffer(rm: ReliabilityManager) =
  withLock rm.lock:
    if rm.incomingBuffer.len == 0:
      return

    # Create dependency map
    var dependencies = initTable[MessageID, seq[MessageID]]()
    var readyToProcess: seq[MessageID] = @[]

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

    # Process ready messages and their dependents
    var newIncomingBuffer: seq[Message] = @[]
    var processed = initHashSet[MessageID]()

    while readyToProcess.len > 0:
      let msgId = readyToProcess.pop()
      if msgId in processed:
        continue

      # Process this message
      for msg in rm.incomingBuffer:
        if msg.messageId == msgId:
          rm.addToHistory(msg.messageId)
          echo "[Nim Core] processIncomingBuffer: Message ready: ", msg.messageId
          if rm.onMessageReady != nil:
            echo "[Nim Core] processIncomingBuffer: Calling onMessageReady for: ",
              msg.messageId
            rm.onMessageReady(rm, msg.messageId) # Pass rm
          else:
            echo "[Nim Core] processIncomingBuffer: rm.onMessageReady is nil, cannot call callback for: ",
              msg.messageId
          processed.incl(msgId)
          # Add any dependent messages that might now be ready
          if msgId in dependencies:
            for dependentId in dependencies[msgId]:
              readyToProcess.add(dependentId)
          break

    # Update incomingBuffer with remaining messages
    for msg in rm.incomingBuffer:
      if msg.messageId notin processed:
        newIncomingBuffer.add(msg)

    rm.incomingBuffer = newIncomingBuffer

proc unwrapReceivedMessage*(
    rm: ReliabilityManager, message: seq[byte]
): Result[tuple[message: seq[byte], missingDeps: seq[MessageID]], ReliabilityError] =
  ## Unwraps a received message and processes its reliability metadata.
  ##
  ## Parameters:
  ##   - message: The received Message object.
  ##
  ## Returns:
  ##   A Result containing either a tuple with the processed message and missing dependencies, or an error.
  try:
    let msgResult = deserializeMessage(message)
    if not msgResult.isOk:
      return err(msgResult.error)

    let msg = msgResult.get
    if rm.bloomFilter.contains(msg.messageId):
      echo "[Nim Core] unwrapReceivedMessage: Duplicate message detected (in bloom filter): ",
        msg.messageId # Add this log
      return ok((msg.content, @[]))

    rm.bloomFilter.add(msg.messageId) # Add to receiver's bloom filter

    # Update Lamport timestamp
    rm.updateLamportTimestamp(msg.lamportTimestamp)

    # Review ACK status for outgoing messages
    rm.reviewAckStatus(msg)

    var missingDeps: seq[MessageID] = @[]
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
        rm.processIncomingBuffer() # This might trigger onMessageReady internally
        # If processIncomingBuffer didn't handle it (e.g., buffer was empty), handle it now.
        # We know deps are met, so it should be ready.
        # NOTE: Need to ensure addToHistory isn't called twice if processIncomingBuffer also adds it.
        # Let's assume processIncomingBuffer handles adding to history if it processes the message.
        # We only call the callback here if it wasn't handled by processIncomingBuffer.
        # A more robust check would involve seeing if msgId was added to 'processed' set in processIncomingBuffer,
        # but let's try simply calling the callback if the condition is met.
        # We already added to history on line 222.
        echo "[Nim Core] unwrapReceivedMessage: Message ready (direct): ", msg.messageId
        # rm.addToHistory(msg.messageId) # Removed potential duplicate add
        if rm.onMessageReady != nil:
          echo "[Nim Core] unwrapReceivedMessage: Calling onMessageReady for: ",
            msg.messageId
          rm.onMessageReady(rm, msg.messageId) # Pass rm
        else:
          echo "[Nim Core] unwrapReceivedMessage: rm.onMessageReady is nil, cannot call callback for: ",
            msg.messageId
    else:
      # Buffer message and request missing dependencies
      echo "[Nim Core] unwrapReceivedMessage: Buffering message due to missing deps: ",
        msg.messageId
      rm.incomingBuffer.add(msg)
      echo "[Nim Core] unwrapReceivedMessage: Checking onMissingDependencies callback for: ",
        msg.messageId
      if rm.onMissingDependencies != nil:
        echo "[Nim Core] unwrapReceivedMessage: Calling onMissingDependencies for: ",
          msg.messageId
        rm.onMissingDependencies(rm, msg.messageId, missingDeps) # Pass rm
      else:
        echo "[Nim Core] unwrapReceivedMessage: rm.onMissingDependencies is nil, cannot call callback for: ",
          msg.messageId

    return ok((msg.content, missingDeps))
  except:
    return err(reInternalError)

proc markDependenciesMet*(
    rm: ReliabilityManager, messageIds: seq[MessageID]
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
    echo "[Nim Core] markDependenciesMet: Calling processIncomingBuffer after marking deps"
    rm.processIncomingBuffer()

    return ok()
  except:
    return err(reInternalError)

proc setCallbacks*(
    rm: ReliabilityManager,
    onMessageReady: proc(rm: ReliabilityManager, messageId: MessageID) {.gcsafe.},
      # Add rm
    onMessageSent: proc(rm: ReliabilityManager, messageId: MessageID) {.gcsafe.},
      # Add rm
    onMissingDependencies: proc(
      rm: ReliabilityManager, messageId: MessageID, missingDeps: seq[MessageID]
    ) {.gcsafe.}, # Add rm
    onPeriodicSync: proc(rm: ReliabilityManager) {.gcsafe.} = nil,
) = # Add rm, make type explicit
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

proc checkUnacknowledgedMessages*(rm: ReliabilityManager) {.raises: [].} =
  ## Checks and processes unacknowledged messages in the outgoing buffer.
  withLock rm.lock:
    let now = getTime()
    var newOutgoingBuffer: seq[UnacknowledgedMessage] = @[]

    try:
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
            if rm.onMessageSent != nil:
              # Assuming message timeout means it's considered "sent" or "failed"
              echo "[Nim Core] checkUnacknowledgedMessages: Calling onMessageSent for timed out message: ",
                unackMsg.message.messageId
              rm.onMessageSent(rm, unackMsg.message.messageId) # Pass rm
            else:
              echo "[Nim Core] checkUnacknowledgedMessages: rm.onMessageSent is nil for timed out message: ",
                unackMsg.message.messageId
        else:
          # Dedent this else to match `if elapsed > rm.config.resendInterval:` (line 296)
          newOutgoingBuffer.add(unackMsg)

      rm.outgoingBuffer = newOutgoingBuffer
    except Exception as e:
      logError("Error in checking unacknowledged messages: " & e.msg)

proc periodicBufferSweep(rm: ReliabilityManager) {.async: (raises: [CancelledError]).} =
  ## Periodically sweeps the buffer to clean up and check unacknowledged messages.
  while true:
    {.gcsafe.}:
      try:
        rm.checkUnacknowledgedMessages()
        rm.cleanBloomFilter()
      except Exception as e:
        logError("Error in periodic buffer sweep: " & e.msg)

    await sleepAsync(chronos.milliseconds(rm.config.bufferSweepInterval.inMilliseconds))

proc periodicSyncMessage(rm: ReliabilityManager) {.async: (raises: [CancelledError]).} =
  ## Periodically notifies to send a sync message to maintain connectivity.
  while true:
    {.gcsafe.}:
      try:
        echo "[Nim Core] periodicSyncMessage: Checking onPeriodicSync callback"
        if rm.onPeriodicSync != nil:
          echo "[Nim Core] periodicSyncMessage: Calling onPeriodicSync"
          rm.onPeriodicSync(rm) # Pass rm
        else:
          echo "[Nim Core] periodicSyncMessage: rm.onPeriodicSync is nil"
      except Exception as e:
        logError("Error in periodic sync: " & e.msg)
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
  ##
  ## Returns:
  ##   A Result indicating success or an error if the Bloom filter initialization fails.
  withLock rm.lock:
    try:
      rm.lamportTimestamp = 0
      rm.messageHistory.setLen(0)
      rm.outgoingBuffer.setLen(0)
      rm.incomingBuffer.setLen(0)
      rm.bloomFilter = newRollingBloomFilter(
        rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate,
        rm.config.bloomFilterWindow,
      )
      return ok()
    except:
      return err(reInternalError)

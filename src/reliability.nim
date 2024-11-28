import ./common, ./utils

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
    maxResendAttempts: DefaultMaxResendAttempts
  )

proc newReliabilityManager*(channelId: string, config: ReliabilityConfig = defaultConfig()): Result[ReliabilityManager] =
  ## Creates a new ReliabilityManager with the specified channel ID and configuration.
  ##
  ## Parameters:
  ##   - channelId: A unique identifier for the communication channel.
  ##   - config: Configuration options for the ReliabilityManager. If not provided, default configuration is used.
  ##
  ## Returns:
  ##   A Result containing either a new ReliabilityManager instance or an error.
  if channelId.len == 0:
    return err[ReliabilityManager](reInvalidArgument)
  
  try:
    let bloomFilterResult = newRollingBloomFilter(config.bloomFilterCapacity, config.bloomFilterErrorRate, config.bloomFilterWindow)
    if bloomFilterResult.isErr:
      return err[ReliabilityManager](bloomFilterResult.error)

    let rm = ReliabilityManager(
      lamportTimestamp: 0,
      messageHistory: @[],
      bloomFilter: bloomFilterResult.value,
      outgoingBuffer: @[],
      incomingBuffer: @[],
      channelId: channelId,
      config: config
    )
    initLock(rm.lock)
    return ok(rm)
  except:
    return err[ReliabilityManager](reOutOfMemory)

proc wrapOutgoingMessage*(rm: ReliabilityManager, message: seq[byte]): Result[seq[byte]] =
  ## Wraps an outgoing message with reliability metadata.
  ##
  ## Parameters:
  ##   - message: The content of the message to be sent.
  ##
  ## Returns:
  ##   A Result containing either a Message object with reliability metadata or an error.
  if message.len == 0:
    return err[Message](reInvalidArgument)
  if message.len > MaxMessageSize:
    return err[Message](reMessageTooLarge)

  withLock rm.lock:
    try:
      let msg = Message(
        senderId: "TODO_SENDER_ID",
        messageId: generateUniqueID(),
        lamportTimestamp: rm.lamportTimestamp,
        causalHistory: rm.getRecentMessageIDs(rm.config.maxCausalHistory),
        channelId: rm.channelId,
        content: message
      )
      rm.updateLamportTimestamp(getTime().toUnix)
      rm.outgoingBuffer.add(UnacknowledgedMessage(message: msg, sendTime: getTime(), resendAttempts: 0))
      return ok(msg)
    except:
      return err[Message](reInternalError)

proc unwrapReceivedMessage*(rm: ReliabilityManager, message: seq[byte]): Result[tuple[message: seq[byte], missingDeps: seq[MessageID]]] =
  ## Unwraps a received message and processes its reliability metadata.
  ##
  ## Parameters:
  ##   - message: The received Message object.
  ##
  ## Returns:
  ##   A Result containing either a tuple with the processed message and missing dependencies, or an error.
  withLock rm.lock:
    try:
      if rm.bloomFilter.contains(message.messageId):
        return ok((message, @[]))

      rm.bloomFilter.add(message.messageId)
      rm.updateLamportTimestamp(message.lamportTimestamp)

      var missingDeps: seq[MessageID] = @[]
      for depId in message.causalHistory:
        if not rm.bloomFilter.contains(depId):
          missingDeps.add(depId)

      if missingDeps.len == 0:
        rm.messageHistory.add(message.messageId)
        if rm.messageHistory.len > rm.config.maxMessageHistory:
          rm.messageHistory.delete(0)
        if rm.onMessageReady != nil:
          rm.onMessageReady(message.messageId)
      else:
        rm.incomingBuffer.add(message)
        if rm.onMissingDependencies != nil:
          rm.onMissingDependencies(message.messageId, missingDeps)

      return ok((message, missingDeps))
    except:
      return err[(Message, seq[MessageID])](reInternalError)

proc markDependenciesMet*(rm: ReliabilityManager, messageIds: seq[MessageID]): Result[void] =
  ## Marks the specified message dependencies as met.
  ##
  ## Parameters:
  ##   - messageIds: A sequence of message IDs to mark as met.
  ##
  ## Returns:
  ##   A Result indicating success or an error.
  withLock rm.lock:
    try:
      var processedMessages: seq[Message] = @[]
      rm.incomingBuffer = rm.incomingBuffer.filterIt(
        not messageIds.allIt(it in it.causalHistory or rm.bloomFilter.contains(it))
      )

      for msg in processedMessages:
        rm.messageHistory.add(msg.messageId)
        if rm.messageHistory.len > rm.config.maxMessageHistory:
          rm.messageHistory.delete(0)
        if rm.onMessageReady != nil:
          rm.onMessageReady(msg.messageId)
      
      return ok()
    except:
      return err[void](reInternalError)

proc setCallbacks*(rm: ReliabilityManager, 
                   onMessageReady: proc(messageId: MessageID), 
                   onMessageSent: proc(messageId: MessageID),
                   onMissingDependencies: proc(messageId: MessageID, missingDeps: seq[MessageID])) =
  ## Sets the callback functions for various events in the ReliabilityManager.
  ##
  ## Parameters:
  ##   - onMessageReady: Callback function called when a message is ready to be processed.
  ##   - onMessageSent: Callback function called when a message is confirmed as sent.
  ##   - onMissingDependencies: Callback function called when a message has missing dependencies.
  withLock rm.lock:
    rm.onMessageReady = onMessageReady
    rm.onMessageSent = onMessageSent
    rm.onMissingDependencies = onMissingDependencies

proc checkUnacknowledgedMessages*(rm: ReliabilityManager) =
  ## Checks and processes unacknowledged messages in the outgoing buffer.
  withLock rm.lock:
    let now = getTime()
    var newOutgoingBuffer: seq[UnacknowledgedMessage] = @[]
    for msg in rm.outgoingBuffer:
      if (now - msg.sendTime) < rm.config.resendInterval:
        newOutgoingBuffer.add(msg)
      elif msg.resendAttempts < rm.config.maxResendAttempts:
        # Resend the message
        msg.resendAttempts += 1
        msg.sendTime = now
        newOutgoingBuffer.add(msg)
        # Here you would actually resend the message
      elif rm.onMessageSent != nil:
        rm.onMessageSent(msg.message.messageId)
    rm.outgoingBuffer = newOutgoingBuffer

proc periodicBufferSweep(rm: ReliabilityManager) {.async.} =
  ## Periodically sweeps the buffer to clean up and resend messages.
  ##
  ## This is an internal function and should not be called directly.
  while true:
    rm.checkUnacknowledgedMessages()
    rm.cleanBloomFilter()
    await sleepAsync(5000)  # Sleep for 5 seconds

proc periodicSyncMessage(rm: ReliabilityManager) {.async.} =
  ## Periodically sends a sync message to maintain connectivity.
  ##
  ## This is an internal function and should not be called directly.
  while true:
    discard rm.wrapOutgoingMessage("")  # Empty content for sync messages
    await sleepAsync(30000)  # Sleep for 30 seconds

proc startPeriodicTasks*(rm: ReliabilityManager) =
  ## Starts the periodic tasks for buffer sweeping and sync message sending.
  ##
  ## This procedure should be called after creating a ReliabilityManager to enable automatic maintenance.
  asyncCheck rm.periodicBufferSweep()
  asyncCheck rm.periodicSyncMessage()

# # To demonstrate how to use the ReliabilityManager
# proc processMessage*(rm: ReliabilityManager, message: string): seq[MessageID] =
#   let wrappedMsg = checkAndLogError(rm.wrapOutgoingMessage(message), "Failed to wrap message")
#   let (_, missingDeps) = checkAndLogError(rm.unwrapReceivedMessage(wrappedMsg), "Failed to unwrap message")
#   return missingDeps

proc resetReliabilityManager*(rm: ReliabilityManager): Result[void] =
  ## Resets the ReliabilityManager to its initial state.
  ##
  ## This procedure clears all buffers and resets the Lamport timestamp.
  ##
  ## Returns:
  ##   A Result indicating success or an error if the Bloom filter initialization fails.
  withLock rm.lock:
    let bloomFilterResult = newRollingBloomFilter(rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate, rm.config.bloomFilterWindow)
    if bloomFilterResult.isErr:
      return err[void](bloomFilterResult.error)

    rm.lamportTimestamp = 0
    rm.messageHistory.setLen(0)
    rm.outgoingBuffer.setLen(0)
    rm.incomingBuffer.setLen(0)
    rm.bloomFilter = bloomFilterResult.value
    return ok()

proc `=destroy`(rm: var ReliabilityManager) =
  ## Destructor for ReliabilityManager. Ensures proper cleanup of resources.
  deinitLock(rm.lock)

when isMainModule:
  # Example usage and basic tests
  let config = defaultConfig()
  let rmResult = newReliabilityManager("testChannel", config)
  if rmResult.isOk:
    let rm = rmResult.value
    rm.setCallbacks(
      proc(messageId: MessageID) = echo "Message ready: ", messageId,
      proc(messageId: MessageID) = echo "Message sent: ", messageId,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) = echo "Missing dependencies for ", messageId, ": ", missingDeps
    )
    
    let msgResult = rm.wrapOutgoingMessage("Hello, World!")
    if msgResult.isOk:
      let msg = msgResult.value
      echo "Wrapped message: ", msg
      
      let unwrapResult = rm.unwrapReceivedMessage(msg)
      if unwrapResult.isOk:
        let (unwrappedMsg, missingDeps) = unwrapResult.value
        echo "Unwrapped message: ", unwrappedMsg
        echo "Missing dependencies: ", missingDeps
      else:
        echo "Error unwrapping message: ", unwrapResult.error
    else:
      echo "Error wrapping message: ", msgResult.error
    
    rm.startPeriodicTasks()
    # In a real application, you'd keep the program running to allow periodic tasks to execute
  else:
    echo "Error creating ReliabilityManager: ", rmResult.error
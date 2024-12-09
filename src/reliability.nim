import std/[times, locks]
import chronos, results
import ./common
import ./utils
import ./protobuf

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

proc newReliabilityManager*(channelId: string, config: ReliabilityConfig = defaultConfig()): Result[ReliabilityManager, ReliabilityError] =
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
      config.bloomFilterCapacity,
      config.bloomFilterErrorRate,
      config.bloomFilterWindow
    )
    
    let rm = ReliabilityManager(
      lamportTimestamp: 0,
      messageHistory: @[],
      bloomFilter: bloomFilter,
      outgoingBuffer: @[],
      incomingBuffer: @[],
      channelId: channelId,
      config: config
    )
    initLock(rm.lock)
    return ok(rm)
  except:
    return err(reOutOfMemory)

proc wrapOutgoingMessage*(rm: ReliabilityManager, message: seq[byte], messageId: MessageID): Result[seq[byte], ReliabilityError] =
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
      let msg = Message(
        messageId: messageId,
        lamportTimestamp: rm.lamportTimestamp,
        causalHistory: rm.getRecentMessageIDs(rm.config.maxCausalHistory),
        channelId: rm.channelId,
        content: message
      )
      rm.outgoingBuffer.add(UnacknowledgedMessage(message: msg, sendTime: getTime(), resendAttempts: 0))
      # rm.messageHistory.add(messageId)
      # rm.bloomFilter.add(messageId)
      return serializeMessage(msg)
    except:
      return err(reInternalError)

proc unwrapReceivedMessage*(rm: ReliabilityManager, message: seq[byte]): Result[tuple[message: seq[byte], missingDeps: seq[MessageID]], ReliabilityError] =
  ## Unwraps a received message and processes its reliability metadata.
  ##
  ## Parameters:
  ##   - message: The received Message object.
  ##
  ## Returns:
  ##   A Result containing either a tuple with the processed message and missing dependencies, or an error.
  withLock rm.lock:
    try:
      let msgResult = deserializeMessage(message)
      if not msgResult.isOk:
        return err(msgResult.error)
      
      let msg = msgResult.get
      if rm.bloomFilter.contains(msg.messageId):
        return ok((msg.content, @[]))

      rm.bloomFilter.add(msg.messageId)
      rm.updateLamportTimestamp(msg.lamportTimestamp)

      var missingDeps: seq[MessageID] = @[]
      for depId in msg.causalHistory:
        if not rm.bloomFilter.contains(depId):
          missingDeps.add(depId)

      if missingDeps.len == 0:
        rm.messageHistory.add(msg.messageId)
        if rm.messageHistory.len > rm.config.maxMessageHistory:
          rm.messageHistory.delete(0)
        if rm.onMessageReady != nil:
          rm.onMessageReady(msg.messageId)
      else:
        rm.incomingBuffer.add(msg)
        if rm.onMissingDependencies != nil:
          rm.onMissingDependencies(msg.messageId, missingDeps)

      return ok((msg.content, missingDeps))
    except:
      return err(reInternalError)

proc markDependenciesMet*(rm: ReliabilityManager, messageIds: seq[MessageID]): Result[void, ReliabilityError] =
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
      var newIncomingBuffer: seq[Message] = @[]
      
      for msg in rm.incomingBuffer:
        var allDependenciesMet = true
        for depId in msg.causalHistory:
          if depId notin messageIds and not rm.bloomFilter.contains(depId):
            allDependenciesMet = false
            break
        
        if allDependenciesMet:
          processedMessages.add(msg)
        else:
          newIncomingBuffer.add(msg)
      
      rm.incomingBuffer = newIncomingBuffer

      for msg in processedMessages:
        rm.messageHistory.add(msg.messageId)
        if rm.messageHistory.len > rm.config.maxMessageHistory:
          rm.messageHistory.delete(0)
        if rm.onMessageReady != nil:
          rm.onMessageReady(msg.messageId)
      
      return ok()
    except:
      return err(reInternalError)

proc setCallbacks*(rm: ReliabilityManager, 
                  onMessageReady: proc(messageId: MessageID) {.gcsafe.}, 
                  onMessageSent: proc(messageId: MessageID) {.gcsafe.},
                  onMissingDependencies: proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.},
                  onPeriodicSync: PeriodicSyncCallback = nil) =
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
      for msg in rm.outgoingBuffer:
        if (now - msg.sendTime) < rm.config.resendInterval:
          newOutgoingBuffer.add(msg)
        elif msg.resendAttempts < rm.config.maxResendAttempts:
          var updatedMsg = msg
          updatedMsg.resendAttempts += 1
          updatedMsg.sendTime = now
          newOutgoingBuffer.add(updatedMsg)
        elif rm.onMessageSent != nil:
          rm.onMessageSent(msg.message.messageId)
      
      rm.outgoingBuffer = newOutgoingBuffer
    except:
      discard

proc periodicBufferSweep(rm: ReliabilityManager) {.async: (raises: [CancelledError]).} =
  ## Periodically sweeps the buffer to clean up and check unacknowledged messages.
  ##
  ## This is an internal function and should not be called directly.
  while true:
    {.gcsafe.}:
      try:
        rm.checkUnacknowledgedMessages()
        rm.cleanBloomFilter()
      except Exception as e:
        logError("Error in periodic buffer sweep: " & e.msg)
    await sleepAsync(chronos.seconds(5))

proc periodicSyncMessage(rm: ReliabilityManager) {.async: (raises: [CancelledError]).} =
  ## Periodically notifies to send a sync message to maintain connectivity.
  while true:
    {.gcsafe.}:
      try:
        if rm.onPeriodicSync != nil:
          rm.onPeriodicSync()
      except Exception as e:
        logError("Error in periodic sync: " & e.msg)
    await sleepAsync(chronos.seconds(30))

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
        rm.config.bloomFilterCapacity,
        rm.config.bloomFilterErrorRate,
        rm.config.bloomFilterWindow
      )
      return ok()
    except:
      return err(reInternalError)

proc cleanup*(rm: ReliabilityManager) {.raises: [].} =
  if not rm.isNil:
    {.gcsafe.}:
      try:
        rm.outgoingBuffer.setLen(0)
        rm.incomingBuffer.setLen(0)
        rm.messageHistory.setLen(0)
      except Exception as e:
        logError("Error during cleanup: " & e.msg)
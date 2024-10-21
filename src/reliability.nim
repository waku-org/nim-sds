import ./common, ./utils

proc defaultConfig*(): ReliabilityConfig =
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

proc wrapOutgoingMessage*(rm: ReliabilityManager, message: string): Result[Message] =
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

proc unwrapReceivedMessage*(rm: ReliabilityManager, message: Message): Result[tuple[message: Message, missingDeps: seq[MessageID]]] =
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
  withLock rm.lock:
    rm.onMessageReady = onMessageReady
    rm.onMessageSent = onMessageSent
    rm.onMissingDependencies = onMissingDependencies

# proc checkUnacknowledgedMessages*(rm: ReliabilityManager) 

proc processMessage*(rm: ReliabilityManager, message: string): seq[MessageID] =
  let wrappedMsg = checkAndLogError(rm.wrapOutgoingMessage(message), "Failed to wrap message")
  let (_, missingDeps) = checkAndLogError(rm.unwrapReceivedMessage(wrappedMsg), "Failed to unwrap message")
  return missingDeps

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
    
    #rm.startPeriodicTasks()
  else:
    echo "Error creating ReliabilityManager: ", rmResult.error
import unittest, results, chronos, chronicles
import ../src/reliability
import ../src/common
import ../src/protobuf
import ../src/utils

suite "ReliabilityManager":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager("testChannel")
    check rmResult.isOk()
    rm = rmResult.get()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "can create with default config":
    let config = defaultConfig()
    check:
      config.bloomFilterCapacity == DefaultBloomFilterCapacity
      config.bloomFilterErrorRate == DefaultBloomFilterErrorRate
      config.bloomFilterWindow == DefaultBloomFilterWindow
      config.maxMessageHistory == DefaultMaxMessageHistory

  test "basic message wrapping and unwrapping":
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"
    
    let wrappedResult = rm.wrapOutgoingMessage(msg, msgId)
    check wrappedResult.isOk()
    let wrapped = wrappedResult.get()
    check wrapped.len > 0

    let unwrapResult = rm.unwrapReceivedMessage(wrapped)
    check unwrapResult.isOk()
    let (unwrapped, missingDeps) = unwrapResult.get()
    check:
      unwrapped == msg
      missingDeps.len == 0

  test "marking dependencies":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = messageReadyCount += 1,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = missingDepsCount += 1
    )

    # Create dependency IDs that aren't in bloom filter yet
    let id1 = "msg1"
    let id2 = "msg2"

    # Create message depending on these IDs
    let msg3 = Message(
      messageId: "msg3",
      lamportTimestamp: 1,
      causalHistory: @[id1, id2],  # Depends on messages we haven't seen
      channelId: "testChannel",
      content: @[byte(3)],
      bloomFilter: @[]
    )

    let serializedMsg3 = serializeMessage(msg3)
    check serializedMsg3.isOk()

    # Process message - should identify missing dependencies
    let unwrapResult = rm.unwrapReceivedMessage(serializedMsg3.get())
    check unwrapResult.isOk()
    let (_, missingDeps) = unwrapResult.get()
    
    check:
      missingDepsCount == 1
      missingDeps.len == 2
      id1 in missingDeps
      id2 in missingDeps

    # Mark dependencies as met
    let markResult = rm.markDependenciesMet(missingDeps)
    check markResult.isOk()

    # Process message again - should now be ready
    let reprocessResult = rm.unwrapReceivedMessage(serializedMsg3.get())
    check reprocessResult.isOk()
    let (_, remainingDeps) = reprocessResult.get()

    check:
      remainingDeps.len == 0
      messageReadyCount == 1
      missingDepsCount == 1

  test "callbacks work correctly":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = messageReadyCount += 1,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = missingDepsCount += 1
    )

    # First send our own message
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1)
    check wrap1.isOk()

    # Create a message that has our message in causal history
    let msg2 = Message(
      messageId: "msg2",
      lamportTimestamp: rm.lamportTimestamp + 1,
      causalHistory: @[id1],  # Include our message in causal history
      channelId: "testChannel",
      content: @[byte(2)],
      bloomFilter: @[]  # Test with an empty bloom filter
    )
    
    let serializedMsg2 = serializeMessage(msg2)
    check serializedMsg2.isOk()

    # Process the "received" message - should trigger callbacks
    let unwrapResult = rm.unwrapReceivedMessage(serializedMsg2.get())
    check unwrapResult.isOk()
    
    check:
      messageReadyCount == 1  # For msg2 which we "received"
      messageSentCount == 1   # For msg1 which was acknowledged via causal history

  test "bloom filter acknowledgment":
    var messageSentCount = 0
    
    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = discard
    )

    # First send our own message
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1)
    check wrap1.isOk()

    # Create a message with bloom filter containing our message
    var otherPartyBloomFilter = newRollingBloomFilter(
      DefaultBloomFilterCapacity,
      DefaultBloomFilterErrorRate,
      DefaultBloomFilterWindow
    )
    otherPartyBloomFilter.add(id1)
    
    let bfResult = serializeBloomFilter(otherPartyBloomFilter.filter)
    check bfResult.isOk()

    let msg2 = Message(
      messageId: "msg2",
      lamportTimestamp: rm.lamportTimestamp + 1,
      causalHistory: @[],  # Empty causal history as we're using bloom filter
      channelId: "testChannel",
      content: @[byte(2)],
      bloomFilter: bfResult.get()
    )

    let serializedMsg2 = serializeMessage(msg2)
    check serializedMsg2.isOk()

    let unwrapResult = rm.unwrapReceivedMessage(serializedMsg2.get())
    check unwrapResult.isOk()
    
    check messageSentCount == 1  # Our message should be acknowledged via bloom filter

  test "periodic sync callback":
    var syncCallCount = 0
    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = discard,
      proc() {.gcsafe.} = syncCallCount += 1
    )

    rm.startPeriodicTasks()
    # Sleep briefly to allow periodic tasks to run
    waitFor sleepAsync(chronos.seconds(1))
    rm.cleanup()
    
    check syncCallCount > 0

  test "buffer management":
    var messageSentCount = 0
    
    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = discard
    )

    # Add multiple messages to outgoing buffer
    for i in 0..5:
      let msg = @[byte(i)]
      let id = "msg" & $i
      let wrap = rm.wrapOutgoingMessage(msg, id)
      check wrap.isOk()

    let outBuffer = rm.getOutgoingBuffer()
    check outBuffer.len == 6

    # Create message that acknowledges some messages
    let ackMsg = Message(
      messageId: "ack1",
      lamportTimestamp: rm.lamportTimestamp + 1,
      causalHistory: @["msg0", "msg2", "msg4"],
      channelId: "testChannel",
      content: @[byte(100)],
      bloomFilter: @[]
    )
    
    let serializedAck = serializeMessage(ackMsg)
    check serializedAck.isOk()
    
    # Process the acknowledgment
    discard rm.unwrapReceivedMessage(serializedAck.get())
    
    let finalBuffer = rm.getOutgoingBuffer()
    check:
      finalBuffer.len == 3  # Should have removed acknowledged messages
      messageSentCount == 3  # Should have triggered sent callback for acknowledged messages

  test "handles empty message":
    let msg: seq[byte] = @[]
    let msgId = "test-empty-msg"
    let wrappedResult = rm.wrapOutgoingMessage(msg, msgId)
    check:
      not wrappedResult.isOk()
      wrappedResult.error == reInvalidArgument

  test "handles message too large":
    let msg = newSeq[byte](MaxMessageSize + 1)
    let msgId = "test-large-msg"
    let wrappedResult = rm.wrapOutgoingMessage(msg, msgId)
    check:
      not wrappedResult.isOk()
      wrappedResult.error == reMessageTooLarge

suite "cleanup":
  test "cleanup works correctly":
    let rmResult = newReliabilityManager("testChannel")
    check rmResult.isOk()
    let rm = rmResult.get()

    # Add some messages
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"
    discard rm.wrapOutgoingMessage(msg, msgId)

    rm.cleanup()

    let outBuffer = rm.getOutgoingBuffer()
    let history = rm.getMessageHistory()
    check:
      outBuffer.len == 0
      history.len == 0
import unittest, results, chronos
import ../src/reliability
import ../src/common
import ../src/protobuf
import ../src/utils

# Core functionality tests
suite "Core Operations":
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

  test "message ordering":
    # Create messages with different timestamps
    let msg1 = Message(
      messageId: "msg1",
      lamportTimestamp: 1,
      causalHistory: @[],
      channelId: "testChannel",
      content: @[byte(1)],
      bloomFilter: @[]
    )

    let msg2 = Message(
      messageId: "msg2",
      lamportTimestamp: 5,
      causalHistory: @[],
      channelId: "testChannel",
      content: @[byte(2)],
      bloomFilter: @[]
    )

    let serialized1 = serializeMessage(msg1)
    let serialized2 = serializeMessage(msg2)
    check:
      serialized1.isOk()
      serialized2.isOk()

    # Process out of order
    discard rm.unwrapReceivedMessage(serialized2.get())
    let timestamp1 = rm.lamportTimestamp
    discard rm.unwrapReceivedMessage(serialized1.get())
    let timestamp2 = rm.lamportTimestamp

    check timestamp2 > timestamp1

# Reliability mechanism tests
suite "Reliability Mechanisms":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager("testChannel")
    check rmResult.isOk()
    rm = rmResult.get()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "dependency detection and resolution":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = messageReadyCount += 1,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = missingDepsCount += 1
    )

    # Create dependency chain: msg3 -> msg2 -> msg1
    let id1 = "msg1"
    let id2 = "msg2"
    let id3 = "msg3"

    # Create messages with dependencies
    let msg2 = Message(
      messageId: id2,
      lamportTimestamp: 2,
      causalHistory: @[id1],  # msg2 depends on msg1
      channelId: "testChannel",
      content: @[byte(2)],
      bloomFilter: @[]
    )

    let msg3 = Message(
      messageId: id3,
      lamportTimestamp: 3,
      causalHistory: @[id1, id2],  # msg3 depends on both msg1 and msg2
      channelId: "testChannel",
      content: @[byte(3)],
      bloomFilter: @[]
    )

    let serialized2 = serializeMessage(msg2)
    let serialized3 = serializeMessage(msg3)
    check:
      serialized2.isOk()
      serialized3.isOk()

    # First try processing msg3 (which depends on msg2 which depends on msg1)
    let unwrapResult3 = rm.unwrapReceivedMessage(serialized3.get())
    check unwrapResult3.isOk()
    let (_, missingDeps3) = unwrapResult3.get()
    
    check:
      missingDepsCount == 1  # Should trigger missing deps callback
      missingDeps3.len == 2  # Should be missing both msg1 and msg2
      id1 in missingDeps3
      id2 in missingDeps3

    # Then try processing msg2 (which only depends on msg1)
    let unwrapResult2 = rm.unwrapReceivedMessage(serialized2.get())
    check unwrapResult2.isOk()
    let (_, missingDeps2) = unwrapResult2.get()
    
    check:
      missingDepsCount == 2  # Should have triggered another missing deps callback
      missingDeps2.len == 1  # Should only be missing msg1
      id1 in missingDeps2
      messageReadyCount == 0  # No messages should be ready yet

    # Mark first dependency (msg1) as met
    let markResult1 = rm.markDependenciesMet(@[id1])
    check markResult1.isOk()

    let incomingBuffer = rm.getIncomingBuffer()

    check:
      incomingBuffer.len == 0
      messageReadyCount == 2  # Both msg2 and msg3 should be ready
      missingDepsCount == 2  # Should still be 2 from the initial missing deps

  test "acknowledgment via causal history":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = messageReadyCount += 1,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = missingDepsCount += 1
    )

    # Send our message
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

  test "acknowledgment via bloom filter":
    var messageSentCount = 0
    
    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = discard
    )

    # Send our message
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

# Periodic task & Buffer management tests
suite "Periodic Tasks & Buffer Management":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager("testChannel")
    check rmResult.isOk()
    rm = rmResult.get()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "outgoing buffer management":
    var messageSentCount = 0
    
    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = discard
    )

    # Add multiple messages
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

  test "periodic buffer sweep":
    var messageSentCount = 0
    
    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = discard
    )

    # Add message to buffer
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1)
    check wrap1.isOk()

    let initialBuffer = rm.getOutgoingBuffer()
    check initialBuffer[0].resendAttempts == 0

    rm.startPeriodicTasks()
    waitFor sleepAsync(chronos.seconds(6))
    
    let finalBuffer = rm.getOutgoingBuffer()
    check:
      finalBuffer.len == 1
      finalBuffer[0].resendAttempts > 0

  test "periodic sync":
    var syncCallCount = 0
    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = discard,
      proc() {.gcsafe.} = syncCallCount += 1
    )

    rm.startPeriodicTasks()
    waitFor sleepAsync(chronos.seconds(1))
    rm.cleanup()
    
    check syncCallCount > 0

# Special cases handling
suite "Special Cases Handling":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager("testChannel")
    check rmResult.isOk()
    rm = rmResult.get()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "message history limits":
    # Add messages up to max history size
    for i in 0..rm.config.maxMessageHistory + 5:
      let msg = @[byte(i)]
      let id = "msg" & $i
      let wrap = rm.wrapOutgoingMessage(msg, id)
      check wrap.isOk()
    
    let history = rm.getMessageHistory()
    check:
      history.len <= rm.config.maxMessageHistory
      history[^1] == "msg" & $(rm.config.maxMessageHistory + 5)

  test "invalid bloom filter handling":
    let msgInvalid = Message(
      messageId: "invalid-bf",
      lamportTimestamp: 1,
      causalHistory: @[],
      channelId: "testChannel",
      content: @[byte(1)],
      bloomFilter: @[1.byte, 2.byte, 3.byte]  # Invalid filter data
    )

    let serializedInvalid = serializeMessage(msgInvalid)
    check serializedInvalid.isOk()

    # Should handle invalid bloom filter gracefully
    let result = rm.unwrapReceivedMessage(serializedInvalid.get())
    check:
      result.isOk()
      result.get()[1].len == 0  # No missing dependencies

  test "duplicate message handling":
    var messageReadyCount = 0
    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = messageReadyCount += 1,
      proc(messageId: MessageID) {.gcsafe.} = discard,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = discard
    )

    # Create and process a message
    let msg = Message(
      messageId: "dup-msg",
      lamportTimestamp: 1,
      causalHistory: @[],
      channelId: "testChannel",
      content: @[byte(1)],
      bloomFilter: @[]
    )

    let serialized = serializeMessage(msg)
    check serialized.isOk()

    # Process same message twice
    let result1 = rm.unwrapReceivedMessage(serialized.get())
    check result1.isOk()
    let result2 = rm.unwrapReceivedMessage(serialized.get())
    check:
      result2.isOk()
      result2.get()[1].len == 0  # No missing deps on second process
      messageReadyCount == 1  # Message should only be processed once

  test "error handling":
    # Empty message
    let emptyMsg: seq[byte] = @[]
    let emptyResult = rm.wrapOutgoingMessage(emptyMsg, "empty")
    check:
      not emptyResult.isOk()
      emptyResult.error == reInvalidArgument

    # Oversized message
    let largeMsg = newSeq[byte](MaxMessageSize + 1)
    let largeResult = rm.wrapOutgoingMessage(largeMsg, "large")
    check:
      not largeResult.isOk()
      largeResult.error == reMessageTooLarge

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
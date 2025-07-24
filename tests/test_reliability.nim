import unittest, results, chronos, std/[times, options, tables]
import ../src/[reliability, message, protobuf, reliability_utils, rolling_bloom_filter]

const testChannel = "testChannel"

# Core functionality tests
suite "Core Operations":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "can create with default config":
    let config = defaultConfig()
    check:
      config.bloomFilterCapacity == DefaultBloomFilterCapacity
      config.bloomFilterErrorRate == DefaultBloomFilterErrorRate
      config.maxMessageHistory == DefaultMaxMessageHistory

  test "basic message wrapping and unwrapping":
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"

    let wrappedResult = rm.wrapOutgoingMessage(msg, msgId, testChannel)
    check wrappedResult.isOk()
    let wrapped = wrappedResult.get()
    check wrapped.len > 0

    let unwrapResult = rm.unwrapReceivedMessage(wrapped)
    check unwrapResult.isOk()
    let (unwrapped, missingDeps, channelId) = unwrapResult.get()
    check:
      unwrapped == msg
      missingDeps.len == 0
      channelId == testChannel

  test "message ordering":
    # Create messages with different timestamps
    let msg1 = SdsMessage(
      messageId: "msg1",
      lamportTimestamp: 1,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(1)],
      bloomFilter: @[],
    )

    let msg2 = SdsMessage(
      messageId: "msg2",
      lamportTimestamp: 5,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[],
    )

    let serialized1 = serializeMessage(msg1)
    let serialized2 = serializeMessage(msg2)
    check:
      serialized1.isOk()
      serialized2.isOk()

    # Process out of order
    discard rm.unwrapReceivedMessage(serialized2.get())
    let timestamp1 = rm.channels[testChannel].lamportTimestamp
    discard rm.unwrapReceivedMessage(serialized1.get())
    let timestamp2 = rm.channels[testChannel].lamportTimestamp

    check timestamp2 > timestamp1

# Reliability mechanism tests
suite "Reliability Mechanisms":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "dependency detection and resolution":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageReadyCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID], channelId: SdsChannelID) {.gcsafe.} =
        missingDepsCount += 1,
    )

    # Create dependency chain: msg3 -> msg2 -> msg1
    let id1 = "msg1"
    let id2 = "msg2"
    let id3 = "msg3"

    # Create messages with dependencies
    let msg2 = SdsMessage(
      messageId: id2,
      lamportTimestamp: 2,
      causalHistory: toCausalHistory(@[id1]), # msg2 depends on msg1
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[],
    )

    let msg3 = SdsMessage(
      messageId: id3,
      lamportTimestamp: 3,
      causalHistory: toCausalHistory(@[id1, id2]), # msg3 depends on both msg1 and msg2
      channelId: testChannel,
      content: @[byte(3)],
      bloomFilter: @[],
    )

    let serialized2 = serializeMessage(msg2)
    let serialized3 = serializeMessage(msg3)
    check:
      serialized2.isOk()
      serialized3.isOk()

    # First try processing msg3 (which depends on msg2 which depends on msg1)
    let unwrapResult3 = rm.unwrapReceivedMessage(serialized3.get())
    check unwrapResult3.isOk()
    let (_, missingDeps3, _) = unwrapResult3.get()

    check:
      missingDepsCount == 1 # Should trigger missing deps callback
      missingDeps3.len == 2 # Should be missing both msg1 and msg2
      id1 in missingDeps3.getMessageIds()
      id2 in missingDeps3.getMessageIds()

    # Then try processing msg2 (which only depends on msg1)
    let unwrapResult2 = rm.unwrapReceivedMessage(serialized2.get())
    check unwrapResult2.isOk()
    let (_, missingDeps2, _) = unwrapResult2.get()

    check:
      missingDepsCount == 2 # Should have triggered another missing deps callback
      missingDeps2.len == 1 # Should only be missing msg1
      id1 in missingDeps2.getMessageIds()
      messageReadyCount == 0 # No messages should be ready yet

    # Mark first dependency (msg1) as met
    let markResult1 = rm.markDependenciesMet(@[id1], testChannel)
    check markResult1.isOk()

    let incomingBuffer = rm.getIncomingBuffer(testChannel)

    check:
      incomingBuffer.len == 0
      messageReadyCount == 2 # Both msg2 and msg3 should be ready
      missingDepsCount == 2 # Should still be 2 from the initial missing deps

  test "acknowledgment via causal history":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageReadyCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID], channelId: SdsChannelID) {.gcsafe.} =
        missingDepsCount += 1,
    )

    # Send our message
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1, testChannel)
    check wrap1.isOk()

    # Create a message that has our message in causal history
    let msg2 = SdsMessage(
      messageId: "msg2",
      lamportTimestamp: rm.channels[testChannel].lamportTimestamp + 1,
      causalHistory: toCausalHistory(@[id1]), # Include our message in causal history
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[] # Test with an empty bloom filter
      ,
    )

    let serializedMsg2 = serializeMessage(msg2)
    check serializedMsg2.isOk()

    # Process the "received" message - should trigger callbacks
    let unwrapResult = rm.unwrapReceivedMessage(serializedMsg2.get())
    check unwrapResult.isOk()

    check:
      messageReadyCount == 1 # For msg2 which we "received"
      messageSentCount == 1 # For msg1 which was acknowledged via causal history

  test "acknowledgment via bloom filter":
    var messageSentCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID], channelId: SdsChannelID) {.gcsafe.} =
        discard,
    )

    # Send our message
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1, testChannel)
    check wrap1.isOk()

    # Create a message with bloom filter containing our message
    var otherPartyBloomFilter =
      newRollingBloomFilter(DefaultBloomFilterCapacity, DefaultBloomFilterErrorRate)
    otherPartyBloomFilter.add(id1)

    let bfResult = serializeBloomFilter(otherPartyBloomFilter.filter)
    check bfResult.isOk()

    let msg2 = SdsMessage(
      messageId: "msg2",
      lamportTimestamp: rm.channels[testChannel].lamportTimestamp + 1,
      causalHistory: @[], # Empty causal history as we're using bloom filter
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: bfResult.get(),
    )

    let serializedMsg2 = serializeMessage(msg2)
    check serializedMsg2.isOk()

    let unwrapResult = rm.unwrapReceivedMessage(serializedMsg2.get())
    check unwrapResult.isOk()

    check messageSentCount == 1 # Our message should be acknowledged via bloom filter

  test "retrieval hints":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageReadyCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID], channelId: SdsChannelID) {.gcsafe.} =
        missingDepsCount += 1,
      nil,
      proc(messageId: SdsMessageID): seq[byte] =
        return cast[seq[byte]]("hint:" & messageId)
    )

    # Send a first message to populate history
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1, testChannel)
    check wrap1.isOk()

    # Send a second message, which should have the first in its causal history
    let msg2 = @[byte(2)]
    let id2 = "msg2"
    let wrap2 = rm.wrapOutgoingMessage(msg2, id2, testChannel)
    check wrap2.isOk()

    # Check that the wrapped message contains the hint
    let unwrappedMsg2 = deserializeMessage(wrap2.get()).get()
    check unwrappedMsg2.causalHistory.len > 0
    check unwrappedMsg2.causalHistory[0].messageId == id1
    check unwrappedMsg2.causalHistory[0].retrievalHint == cast[seq[byte]]("hint:" & id1)

    # Create a message with a missing dependency
    let msg3 = SdsMessage(
      messageId: "msg3",
      lamportTimestamp: 3,
      causalHistory: toCausalHistory(@["missing-dep"]),
      channelId: testChannel,
      content: @[byte(3)],
      bloomFilter: @[],
    )
    let serialized3 = serializeMessage(msg3).get()
    let unwrapResult3 = rm.unwrapReceivedMessage(serialized3)
    check unwrapResult3.isOk()
    let (_, missingDeps3, _) = unwrapResult3.get()
    check missingDeps3.len == 1
    check missingDeps3[0].messageId == "missing-dep"
    # The hint is empty because it was not in our history, so the provider was not called
    check missingDeps3[0].retrievalHint.len == 0

# Periodic task & Buffer management tests
suite "Periodic Tasks & Buffer Management":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "outgoing buffer management":
    var messageSentCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID], channelId: SdsChannelID) {.gcsafe.} =
        discard,
    )

    # Add multiple messages
    for i in 0 .. 5:
      let msg = @[byte(i)]
      let id = "msg" & $i
      let wrap = rm.wrapOutgoingMessage(msg, id, testChannel)
      check wrap.isOk()

    let outBuffer = rm.getOutgoingBuffer(testChannel)
    check outBuffer.len == 6

    # Create message that acknowledges some messages
    let ackMsg = SdsMessage(
      messageId: "ack1",
      lamportTimestamp: rm.channels[testChannel].lamportTimestamp + 1,
      causalHistory: toCausalHistory(@["msg0", "msg2", "msg4"]),
      channelId: testChannel,
      content: @[byte(100)],
      bloomFilter: @[],
    )

    let serializedAck = serializeMessage(ackMsg)
    check serializedAck.isOk()

    # Process the acknowledgment
    discard rm.unwrapReceivedMessage(serializedAck.get())

    let finalBuffer = rm.getOutgoingBuffer(testChannel)
    check:
      finalBuffer.len == 3 # Should have removed acknowledged messages
      messageSentCount == 3
        # Should have triggered sent callback for acknowledged messages

  test "periodic buffer sweep and bloom clean":
    var messageSentCount = 0

    var config = defaultConfig()
    config.resendInterval = initDuration(milliseconds = 100) # Short for testing
    config.bufferSweepInterval = initDuration(milliseconds = 50) # Frequent sweeps
    config.bloomFilterCapacity = 2 # Small capacity for testing
    config.maxResendAttempts = 3 # Set a low number of max attempts

    let rmResultP = newReliabilityManager(config)
    check rmResultP.isOk()
    let rm = rmResultP.get()
    check rm.ensureChannel(testChannel).isOk()

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID], channelId: SdsChannelID) {.gcsafe.} =
        discard,
    )

    # First message - should be cleaned from bloom filter later
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1, testChannel)
    check wrap1.isOk()

    let initialBuffer = rm.getOutgoingBuffer(testChannel)
    check:
      initialBuffer[0].resendAttempts == 0
      rm.channels[testChannel].bloomFilter.contains(id1)

    rm.startPeriodicTasks()

    # Wait long enough for bloom filter
    waitFor sleepAsync(chronos.milliseconds(500))

    # Add new messages
    let msg2 = @[byte(2)]
    let id2 = "msg2"
    let wrap2 = rm.wrapOutgoingMessage(msg2, id2, testChannel)
    check wrap2.isOk()

    let msg3 = @[byte(3)]
    let id3 = "msg3"
    let wrap3 = rm.wrapOutgoingMessage(msg3, id3, testChannel)
    check wrap3.isOk()

    let finalBuffer = rm.getOutgoingBuffer(testChannel)
    check:
      finalBuffer.len == 2
        # Only msg2 and msg3 should be in buffer, msg1 should be removed after max retries
      finalBuffer[0].message.messageId == id2 # Verify it's the second message
      finalBuffer[0].resendAttempts == 0 # New message should have 0 attempts
      not rm.channels[testChannel].bloomFilter.contains(id1) # Bloom filter cleaning check
      rm.channels[testChannel].bloomFilter.contains(id3) # New message still in filter

    rm.cleanup()

  test "periodic sync callback":
    var syncCallCount = 0
    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID], channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc() {.gcsafe.} =
        syncCallCount += 1,
    )

    rm.startPeriodicTasks()
    waitFor sleepAsync(chronos.seconds(1))
    rm.cleanup()

    check syncCallCount > 0

# Special cases handling
suite "Special Cases Handling":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "message history limits":
    # Add messages up to max history size
    for i in 0 .. rm.config.maxMessageHistory + 5:
      let msg = @[byte(i)]
      let id = "msg" & $i
      let wrap = rm.wrapOutgoingMessage(msg, id, testChannel)
      check wrap.isOk()

    let history = rm.getMessageHistory(testChannel)
    check:
      history.len <= rm.config.maxMessageHistory
      history[^1] == "msg" & $(rm.config.maxMessageHistory + 5)

  test "invalid bloom filter handling":
    let msgInvalid = SdsMessage(
      messageId: "invalid-bf",
      lamportTimestamp: 1,
      causalHistory: toCausalHistory(@[]),
      channelId: testChannel,
      content: @[byte(1)],
      bloomFilter: @[1.byte, 2.byte, 3.byte] # Invalid filter data
      ,
    )

    let serializedInvalid = serializeMessage(msgInvalid)
    check serializedInvalid.isOk()

    # Should handle invalid bloom filter gracefully
    let result = rm.unwrapReceivedMessage(serializedInvalid.get())
    check:
      result.isOk()
      result.get()[1].len == 0 # No missing dependencies

  test "duplicate message handling":
    var messageReadyCount = 0
    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageReadyCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, missingDeps: seq[SdsMessageID], channelId: SdsChannelID) {.gcsafe.} =
        discard,
    )

    # Create and process a message
    let msg = SdsMessage(
      messageId: "dup-msg",
      lamportTimestamp: 1,
      causalHistory: toCausalHistory(@[]),
      channelId: testChannel,
      content: @[byte(1)],
      bloomFilter: @[],
    )

    let serialized = serializeMessage(msg)
    check serialized.isOk()

    # Process same message twice
    let result1 = rm.unwrapReceivedMessage(serialized.get())
    check result1.isOk()
    let result2 = rm.unwrapReceivedMessage(serialized.get())
    check:
      result2.isOk()
      result2.get()[1].len == 0 # No missing deps on second process
      messageReadyCount == 1 # Message should only be processed once

  test "error handling":
    # Empty message
    let emptyMsg: seq[byte] = @[]
    let emptyResult = rm.wrapOutgoingMessage(emptyMsg, "empty", testChannel)
    check:
      not emptyResult.isOk()
      emptyResult.error == reInvalidArgument

    # Oversized message
    let largeMsg = newSeq[byte](MaxMessageSize + 1)
    let largeResult = rm.wrapOutgoingMessage(largeMsg, "large", testChannel)
    check:
      not largeResult.isOk()
      largeResult.error == reMessageTooLarge

suite "cleanup":
  test "cleanup works correctly":
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    let rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

    # Add some messages
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"
    discard rm.wrapOutgoingMessage(msg, msgId, testChannel)

    rm.cleanup()

    let outBuffer = rm.getOutgoingBuffer(testChannel)
    let history = rm.getMessageHistory(testChannel)
    check:
      outBuffer.len == 0
      history.len == 0

suite "Multi-Channel ReliabilityManager Tests":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "can create multi-channel manager without channel ID":
    check rm.channels.len == 0

  test "channel management":
    let channel1 = "channel1"
    let channel2 = "channel2"

    # Ensure channels
    check rm.ensureChannel(channel1).isOk()
    check rm.ensureChannel(channel2).isOk()
    check rm.channels.len == 2

    # Remove channel
    check rm.removeChannel(channel1).isOk()
    check rm.channels.len == 1
    check channel1 notin rm.channels
    check channel2 in rm.channels

  test "stateless message unwrapping with channel extraction":
    let channel1 = "test-channel-1"
    let channel2 = "test-channel-2"

    # Create and wrap messages for different channels
    let msg1 = @[byte(1), 2, 3]
    let msgId1 = "msg1"
    let wrapped1 = rm.wrapOutgoingMessage(msg1, msgId1, channel1)
    check wrapped1.isOk()

    let msg2 = @[byte(4), 5, 6]
    let msgId2 = "msg2"
    let wrapped2 = rm.wrapOutgoingMessage(msg2, msgId2, channel2)
    check wrapped2.isOk()

    # Unwrap messages - should extract channel ID and route correctly
    let unwrap1 = rm.unwrapReceivedMessage(wrapped1.get())
    check unwrap1.isOk()
    let (content1, deps1, extractedChannel1) = unwrap1.get()
    check:
      content1 == msg1
      deps1.len == 0
      extractedChannel1 == channel1

    let unwrap2 = rm.unwrapReceivedMessage(wrapped2.get())
    check unwrap2.isOk()
    let (content2, deps2, extractedChannel2) = unwrap2.get()
    check:
      content2 == msg2
      deps2.len == 0
      extractedChannel2 == channel2

  test "channel isolation":
    let channel1 = "isolated-channel-1"
    let channel2 = "isolated-channel-2"

    # Add messages to different channels
    let msg1 = @[byte(1)]
    let msgId1 = "isolated-msg1"
    discard rm.wrapOutgoingMessage(msg1, msgId1, channel1)

    let msg2 = @[byte(2)]
    let msgId2 = "isolated-msg2"
    discard rm.wrapOutgoingMessage(msg2, msgId2, channel2)

    # Check channel-specific data is isolated
    let history1 = rm.getMessageHistory(channel1)
    let history2 = rm.getMessageHistory(channel2)

    check:
      history1.len == 1
      history2.len == 1
      msgId1 in history1
      msgId2 in history2
      msgId1 notin history2
      msgId2 notin history1

  test "multi-channel callbacks":
    var readyMessageCount = 0
    var sentMessageCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        readyMessageCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        sentMessageCount += 1,
      proc(messageId: SdsMessageID, deps: seq[SdsMessageID], channelId: SdsChannelID) {.gcsafe.} =
        missingDepsCount += 1
    )

    let channel1 = "callback-channel-1"
    let channel2 = "callback-channel-2"

    # Send messages from both channels
    let msg1 = @[byte(1)]
    let msgId1 = "callback-msg1"
    let wrapped1 = rm.wrapOutgoingMessage(msg1, msgId1, channel1)
    check wrapped1.isOk()

    let msg2 = @[byte(2)]
    let msgId2 = "callback-msg2"
    let wrapped2 = rm.wrapOutgoingMessage(msg2, msgId2, channel2)
    check wrapped2.isOk()

    # Create acknowledgment messages that include our message IDs in causal history
    # to trigger sent callbacks
    let ackMsg1 = SdsMessage(
      messageId: "ack1",
      lamportTimestamp: rm.channels[channel1].lamportTimestamp + 1,
      causalHistory: toCausalHistory(@[msgId1]), # Acknowledge msg1
      channelId: channel1,
      content: @[byte(100)],
      bloomFilter: @[],
    )

    let ackMsg2 = SdsMessage(
      messageId: "ack2",
      lamportTimestamp: rm.channels[channel2].lamportTimestamp + 1,
      causalHistory: toCausalHistory(@[msgId2]), # Acknowledge msg2
      channelId: channel2,
      content: @[byte(101)],
      bloomFilter: @[],
    )

    let serializedAck1 = serializeMessage(ackMsg1)
    let serializedAck2 = serializeMessage(ackMsg2)
    check:
      serializedAck1.isOk()
      serializedAck2.isOk()

    # Process acknowledgment messages - should trigger callbacks
    discard rm.unwrapReceivedMessage(serializedAck1.get())
    discard rm.unwrapReceivedMessage(serializedAck2.get())

    check:
      readyMessageCount == 2  # Both ack messages should trigger ready callbacks
      sentMessageCount == 2  # Both original messages should be marked as sent
      missingDepsCount == 0   # No missing dependencies

  test "channel-specific dependency management":
    let channel1 = "dep-channel-1"
    let channel2 = "dep-channel-2"
    let depIds = @["dep1", "dep2", "dep3"]

    # Ensure both channels exist first
    check rm.ensureChannel(channel1).isOk()
    check rm.ensureChannel(channel2).isOk()

    # Mark dependencies as met for specific channel
    check rm.markDependenciesMet(depIds, channel1).isOk()

    # Dependencies should only affect the specified channel
    # Dependencies in channel1 should not affect channel2
    check rm.channels[channel1].bloomFilter.contains("dep1")
    check not rm.channels[channel2].bloomFilter.contains("dep1")

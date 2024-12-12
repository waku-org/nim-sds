import unittest, results, chronos
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
    check config.bloomFilterCapacity == DefaultBloomFilterCapacity
    check config.bloomFilterErrorRate == DefaultBloomFilterErrorRate
    check config.bloomFilterWindow == DefaultBloomFilterWindow

  test "wrapOutgoingMessage":
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"
    let wrappedResult = rm.wrapOutgoingMessage(msg, msgId)
    check wrappedResult.isOk()
    let wrapped = wrappedResult.get()
    check wrapped.len > 0

  test "unwrapReceivedMessage":
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"
    let wrappedResult = rm.wrapOutgoingMessage(msg, msgId)
    check wrappedResult.isOk()
    let wrapped = wrappedResult.get()
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

    # We'll create dependency IDs that aren't in the bloom filter yet
    let id1 = "msg1"
    let id2 = "msg2"

    # Create a message that depends on these IDs
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

    # Process the message - should identify missing dependencies
    let unwrapResult = rm.unwrapReceivedMessage(serializedMsg3.get())
    check unwrapResult.isOk()
    let (_, missingDeps) = unwrapResult.get()
    
    # Verify missing dependencies were identified
    check missingDepsCount == 1
    check missingDeps.len == 2
    check id1 in missingDeps
    check id2 in missingDeps

    # Now mark dependencies as met
    let markResult = rm.markDependenciesMet(missingDeps)
    check markResult.isOk()

    # Process the message again - should now be ready
    let reprocessResult = rm.unwrapReceivedMessage(serializedMsg3.get())
    check reprocessResult.isOk()
    let (_, remainingDeps) = reprocessResult.get()

    # Verify message is now processed
    check remainingDeps.len == 0
    check messageReadyCount == 1  # msg3 should now be ready
    check missingDepsCount == 1   # Only the first attempt should report missing deps

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
    
    check messageReadyCount == 1  # For msg2 which we "received"
    check messageSentCount == 1   # For msg1 which was acknowledged via causal history

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

    # Create a message simulating another party's message
    # with bloom filter containing our message
    var otherPartyBloomFilter = newRollingBloomFilter(
      DefaultBloomFilterCapacity,
      DefaultBloomFilterErrorRate,
      DefaultBloomFilterWindow
    )
    otherPartyBloomFilter.add(id1)  # Add our message to their bloom filter
    
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

    # Process the "received" message - should trigger acknowledgment
    let unwrapResult = rm.unwrapReceivedMessage(serializedMsg2.get())
    check unwrapResult.isOk()
    
    check messageSentCount == 1  # Our message should be acknowledged via bloom filter

  test "periodic sync callback works":
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
    
    check(syncCallCount > 0)

  test "protobuf serialization":
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"
    let msgResult = rm.wrapOutgoingMessage(msg, msgId)
    check msgResult.isOk()
    let wrapped = msgResult.get()
    
    let unwrapResult = rm.unwrapReceivedMessage(wrapped)
    check unwrapResult.isOk()
    let (unwrapped, _) = unwrapResult.get()
    
    check:
      unwrapped == msg
      unwrapped.len == msg.len

  test "handles empty message":
    let msg: seq[byte] = @[]
    let msgId = "test-empty-msg"
    let wrappedResult = rm.wrapOutgoingMessage(msg, msgId)
    check(not wrappedResult.isOk())
    check(wrappedResult.error == reInvalidArgument)

  test "handles message too large":
    let msg = newSeq[byte](MaxMessageSize + 1)
    let msgId = "test-large-msg"
    let wrappedResult = rm.wrapOutgoingMessage(msg, msgId)
    check(not wrappedResult.isOk())
    check(wrappedResult.error == reMessageTooLarge)

suite "cleanup":
  test "cleanup works correctly":
    let rmResult = newReliabilityManager("testChannel")
    check rmResult.isOk()
    let rm = rmResult.get()

    # Add some messages
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"
    discard rm.wrapOutgoingMessage(msg, msgId)

    # Cleanup
    rm.cleanup()

    # Check buffers are empty
    check(rm.outgoingBuffer.len == 0)
    check(rm.incomingBuffer.len == 0)
    check(rm.messageHistory.len == 0)
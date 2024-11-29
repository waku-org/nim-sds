import unittest, results, chronos, chronicles
import ../src/reliability
import ../src/common

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

  test "markDependenciesMet":
    info "test_state", state="starting markDependenciesMet test"

    block message1:
      let msg1 = @[byte(1)]
      let id1 = "msg1"
      info "message_creation", msg="message 1", id=id1
      let wrap1 = rm.wrapOutgoingMessage(msg1, id1)
      check wrap1.isOk()
      let wrapped1 = wrap1.get()

      info "message_processing", msg="message 1", id=id1
      let unwrap1 = rm.unwrapReceivedMessage(wrapped1)
      check unwrap1.isOk()
      let (content1, deps1) = unwrap1.get()
      info "message_processed", msg="message 1", deps_count=deps1.len
      check content1 == msg1

    block message2:
      let msg2 = @[byte(2)]
      let id2 = "msg2"
      info "message_creation", msg="message 2", id=id2
      let wrap2 = rm.wrapOutgoingMessage(msg2, id2)
      check wrap2.isOk()
      let wrapped2 = wrap2.get()

      info "message_processing", msg="message 2", id=id2
      let unwrap2 = rm.unwrapReceivedMessage(wrapped2)
      check unwrap2.isOk()
      let (content2, deps2) = unwrap2.get()
      info "message_processed", msg="message 2", deps_count=deps2.len
      check content2 == msg2

    block message3:
      info "message_creation", msg="message 3"
      let msg3 = @[byte(3)]
      let id3 = "msg3"
      let wrap3 = rm.wrapOutgoingMessage(msg3, id3)
      check wrap3.isOk()
      info "message_wrapped", msg="message 3", id=id3
      let wrapped3 = wrap3.get()

      info "checking_dependencies", msg="message 3", id=id3
      var unwrap3 = rm.unwrapReceivedMessage(wrapped3)
      check unwrap3.isOk()
      var (content3, missing3) = unwrap3.get()
      info "dependencies_checked", msg="message 3", missing_deps=missing3.len

    info "test_state", state="completed"

  test "callbacks work correctly":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: MessageID) {.gcsafe.} = messageReadyCount += 1,
      proc(messageId: MessageID) {.gcsafe.} = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.} = missingDepsCount += 1
    )

    let msg1Result = rm.wrapOutgoingMessage(@[byte(1)], "msg1")
    let msg2Result = rm.wrapOutgoingMessage(@[byte(2)], "msg2")
    check msg1Result.isOk() and msg2Result.isOk()
    let msg1 = msg1Result.get()
    let msg2 = msg2Result.get()
    discard rm.unwrapReceivedMessage(msg1)
    discard rm.unwrapReceivedMessage(msg2)

    check:
      messageReadyCount == 2
      messageSentCount == 0  # This would be triggered by checkUnacknowledgedMessages
      missingDepsCount == 0

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
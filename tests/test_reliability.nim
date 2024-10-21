import unittest
import ../src/reliability

suite "ReliabilityManager":
  setup:
    let rmResult = newReliabilityManager("testChannel")
    check rmResult.isOk
    let rm = rmResult.value

  test "wrapOutgoingMessage":
    let msgResult = rm.wrapOutgoingMessage("Hello, World!")
    check msgResult.isOk
    let msg = msgResult.value
    check:
      msg.content == "Hello, World!"
      msg.channelId == "testChannel"
      msg.causalHistory.len == 0

  test "unwrapReceivedMessage":
    let wrappedMsgResult = rm.wrapOutgoingMessage("Test message")
    check wrappedMsgResult.isOk
    let wrappedMsg = wrappedMsgResult.value
    let unwrapResult = rm.unwrapReceivedMessage(wrappedMsg)
    check unwrapResult.isOk
    let (unwrappedMsg, missingDeps) = unwrapResult.value
    check:
      unwrappedMsg.content == "Test message"
      missingDeps.len == 0

  test "markDependenciesMet":
    var msg1Result = rm.wrapOutgoingMessage("Message 1")
    var msg2Result = rm.wrapOutgoingMessage("Message 2")
    var msg3Result = rm.wrapOutgoingMessage("Message 3")
    check msg1Result.isOk and msg2Result.isOk and msg3Result.isOk
    let msg1 = msg1Result.value
    let msg2 = msg2Result.value
    let msg3 = msg3Result.value

    var unwrapResult = rm.unwrapReceivedMessage(msg3)
    check unwrapResult.isOk
    var (_, missingDeps) = unwrapResult.value
    check missingDeps.len == 2

    let markResult = rm.markDependenciesMet(@[msg1.messageId, msg2.messageId])
    check markResult.isOk

    unwrapResult = rm.unwrapReceivedMessage(msg3)
    check unwrapResult.isOk
    (_, missingDeps) = unwrapResult.value
    check missingDeps.len == 0

  test "callbacks":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: MessageID) = messageReadyCount += 1,
      proc(messageId: MessageID) = messageSentCount += 1,
      proc(messageId: MessageID, missingDeps: seq[MessageID]) = missingDepsCount += 1
    )

    let msg1Result = rm.wrapOutgoingMessage("Message 1")
    let msg2Result = rm.wrapOutgoingMessage("Message 2")
    check msg1Result.isOk and msg2Result.isOk
    let msg1 = msg1Result.value
    let msg2 = msg2Result.value
    discard rm.unwrapReceivedMessage(msg1)
    discard rm.unwrapReceivedMessage(msg2)

    check:
      messageReadyCount == 2
      messageSentCount == 0  # This would be triggered by the checkUnacknowledgedMessages function
      missingDepsCount == 0

  test "serialization":
    let msgResult = rm.wrapOutgoingMessage("Test serialization")
    check msgResult.isOk
    let msg = msgResult.value
    let serializeResult = serializeMessage(msg)
    check serializeResult.isOk
    let serialized = serializeResult.value
    let deserializeResult = deserializeMessage(serialized)
    check deserializeResult.isOk
    let deserialized = deserializeResult.value
    check:
      deserialized.content == "Test serialization"
      deserialized.messageId == msg.messageId
      deserialized.lamportTimestamp == msg.lamportTimestamp

when isMainModule:
  unittest.run()
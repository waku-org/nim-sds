import unittest
import ../src/reliability

suite "ReliabilityManager":
  setup:
    let rm = newReliabilityManager("testChannel")

  test "wrapOutgoingMessage":
    let msg = rm.wrapOutgoingMessage("Hello, World!")
    check:
      msg.content == "Hello, World!"
      msg.channelId == "testChannel"
      msg.causalHistory.len == 0

  test "unwrapReceivedMessage":
    let wrappedMsg = rm.wrapOutgoingMessage("Test message")
    let (unwrappedMsg, missingDeps) = rm.unwrapReceivedMessage(wrappedMsg)
    check:
      unwrappedMsg.content == "Test message"
      missingDeps.len == 0

  test "markDependenciesMet":
    let msg1 = rm.wrapOutgoingMessage("Message 1")
    let msg2 = rm.wrapOutgoingMessage("Message 2")
    let msg3 = rm.wrapOutgoingMessage("Message 3")

    var (_, missingDeps) = rm.unwrapReceivedMessage(msg3)
    check missingDeps.len == 2

    rm.markDependenciesMet(@[msg1.messageId, msg2.messageId])
    (_, missingDeps) = rm.unwrapReceivedMessage(msg3)
    check missingDeps.len == 0

  test "callbacks":
    var messageReadyCount = 0
    var messageSentCount = 0
    var periodicSyncCount = 0

    rm.setCallbacks(
      proc(messageId: MessageID) = messageReadyCount += 1,
      proc(messageId: MessageID) = messageSentCount += 1,
      proc() = periodicSyncCount += 1
    )

    let msg = rm.wrapOutgoingMessage("Test callback")
    discard rm.unwrapReceivedMessage(msg)

    check:
      messageReadyCount == 1
      messageSentCount == 0  # This would be triggered by the checkUnacknowledgedMessages function
      periodicSyncCount == 0  # This would be triggered by the periodicSync function

  test "lamport timestamps":
    let msg1 = rm.wrapOutgoingMessage("Message 1")
    let msg2 = rm.wrapOutgoingMessage("Message 2")
    check msg2.lamportTimestamp > msg1.lamportTimestamp

    let msg3 = Message(lamportTimestamp: msg2.lamportTimestamp + 10, messageId: generateUniqueID(), content: "Message 3")
    discard rm.unwrapReceivedMessage(msg3)
    let msg4 = rm.wrapOutgoingMessage("Message 4")
    check msg4.lamportTimestamp > msg3.lamportTimestamp

  test "causal history":
    let msg1 = rm.wrapOutgoingMessage("Message 1")
    let msg2 = rm.wrapOutgoingMessage("Message 2")
    let msg3 = rm.wrapOutgoingMessage("Message 3")
    
    check:
      msg2.causalHistory.contains(msg1.messageId)
      msg3.causalHistory.contains(msg2.messageId)
      msg3.causalHistory.contains(msg1.messageId)

  test "bloom filter":
    let msg1 = rm.wrapOutgoingMessage("Message 1")
    let (_, missingDeps1) = rm.unwrapReceivedMessage(msg1)
    check missingDeps1.len == 0

    let (_, missingDeps2) = rm.unwrapReceivedMessage(msg1)
    check missingDeps2.len == 0  # The message should be in the bloom filter and not processed again
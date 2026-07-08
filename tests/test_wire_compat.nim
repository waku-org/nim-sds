## Verifies that a message encoded by the new (field-3 = repeated string +
## additive field-7 hints) codec is still readable by a pre-retrieval-hint
## (v0.2.x) node, which decodes field 3 as a repeated string of message IDs and
## ignores unknown field 7.

import std/unittest
import libp2p/protobuf/minprotobuf
import ../src/[message, protobuf, reliability_utils]

# Exact v0.2.5 decoder for the causal-history portion (repeated string, field 3).
proc oldDecodeCausalHistory(buffer: seq[byte]): seq[SdsMessageID] =
  let pb = initProtoBuffer(buffer)
  var causalHistory: seq[SdsMessageID]
  discard pb.getRepeatedField(3, causalHistory)
  causalHistory

suite "SDS wire backward-compatibility":
  test "old node reads causal history from new-encoded message":
    let msg = SdsMessage(
      messageId: "0xdeadbeef",
      lamportTimestamp: 7,
      causalHistory: @[
        HistoryEntry(messageId: "0xaaa", retrievalHint: @[byte 1, 2, 3]),
        HistoryEntry(messageId: "0xbbb", retrievalHint: @[]),
      ],
      channelId: "0xchannel",
      content: @[byte 9, 9, 9],
      bloomFilter: @[],
    )

    let wire = encode(msg).buffer

    # An old node recovers the EXACT message IDs (not garbled submessage bytes)
    # and simply never sees the hints.
    let oldIds = oldDecodeCausalHistory(wire)
    check oldIds == @["0xaaa", "0xbbb"]

    # Old node still reads content and channel.
    let pb = initProtoBuffer(wire)
    var content: seq[byte]
    var channelId: SdsChannelID
    check pb.getField(5, content).get(false)
    check content == @[byte 9, 9, 9]
    check pb.getField(4, channelId).get(false)
    check channelId == "0xchannel"

  test "new node round-trips message IDs and hints":
    let msg = SdsMessage(
      messageId: "0xfeed",
      lamportTimestamp: 3,
      causalHistory: @[
        HistoryEntry(messageId: "0xaaa", retrievalHint: @[byte 1, 2, 3]),
        HistoryEntry(messageId: "0xbbb", retrievalHint: @[]),
      ],
      channelId: "0xchannel",
      content: @[byte 1],
      bloomFilter: @[],
    )

    let decoded = SdsMessage.decode(encode(msg).buffer).get()
    check decoded.causalHistory.len == 2
    check decoded.causalHistory[0].messageId == "0xaaa"
    check decoded.causalHistory[0].retrievalHint == @[byte 1, 2, 3]
    check decoded.causalHistory[1].messageId == "0xbbb"
    check decoded.causalHistory[1].retrievalHint.len == 0

  test "new node decodes legacy message (field 3 repeated string, no field 7)":
    # Build a message the way a v0.2.5 node would: field 3 = bare strings.
    var pb = initProtoBuffer()
    pb.write(1, "0xlegacy")
    pb.write(2, uint64(1))
    pb.write(3, "0xaaa")
    pb.write(3, "0xbbb")
    pb.write(4, "0xchannel")
    pb.write(5, @[byte 5])
    pb.finish()

    let decoded = SdsMessage.decode(pb.buffer).get()
    check decoded.causalHistory.getMessageIds() == @["0xaaa", "0xbbb"]
    check decoded.causalHistory[0].retrievalHint.len == 0

import libp2p/protobuf/minprotobuf
import std/tables
import endians
import ../src/[message, protobufutil, bloom, reliability_utils]

proc encode*(msg: SdsMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.messageId)
  pb.write(2, uint64(msg.lamportTimestamp))

  # Field 3 stays wire-compatible with pre-retrieval-hint nodes (v0.2.x): a
  # repeated string of message IDs. Retrieval hints ride in the additive field 7
  # (repeated HistoryEntry submessage, keyed by message ID), which older nodes
  # skip as an unknown field while still reading the causal history correctly.
  for entry in msg.causalHistory:
    pb.write(3, entry.messageId)
    if entry.retrievalHint.len > 0:
      var hintPb = initProtoBuffer()
      hintPb.write(1, entry.messageId)
      hintPb.write(2, entry.retrievalHint)
      hintPb.finish()
      pb.write(7, hintPb.buffer)

  pb.write(4, msg.channelId)
  pb.write(5, msg.content)
  pb.write(6, msg.bloomFilter)
  pb.finish()

  pb

proc decode*(T: type SdsMessage, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var msg = SdsMessage()

  if not ?pb.getField(1, msg.messageId):
    return err(ProtobufError.missingRequiredField("messageId"))

  var timestamp: uint64
  if not ?pb.getField(2, timestamp):
    return err(ProtobufError.missingRequiredField("lamportTimestamp"))
  msg.lamportTimestamp = int64(timestamp)

  # Causal history: field 3 is a repeated string of message IDs (as understood
  # by every SDS version). Optional retrieval hints arrive in the additive
  # field 7 (repeated HistoryEntry submessage keyed by message ID) and are
  # simply absent on messages from pre-retrieval-hint nodes.
  var messageIds: seq[SdsMessageID]
  if pb.getRepeatedField(3, messageIds).isOk():
    var hints = initTable[SdsMessageID, seq[byte]]()
    var hintBuffers: seq[seq[byte]]
    if pb.getRepeatedField(7, hintBuffers).isOk():
      for hintBuffer in hintBuffers:
        let hintPb = initProtoBuffer(hintBuffer)
        var hintId: SdsMessageID
        var hint: seq[byte]
        # Malformed/partial hints are ignored: they never break decoding, since
        # the message ID (field 3) already carries the authoritative dependency.
        if hintPb.getField(1, hintId).valueOr(false) and
            hintPb.getField(2, hint).valueOr(false):
          hints[hintId] = hint
    for messageId in messageIds:
      msg.causalHistory.add(
        HistoryEntry(messageId: messageId, retrievalHint: hints.getOrDefault(messageId))
      )

  if not ?pb.getField(4, msg.channelId):
    return err(ProtobufError.missingRequiredField("channelId"))

  if not ?pb.getField(5, msg.content):
    return err(ProtobufError.missingRequiredField("content"))

  if not ?pb.getField(6, msg.bloomFilter):
    msg.bloomFilter = @[] # Empty if not present

  ok(msg)

proc extractChannelId*(data: seq[byte]): Result[SdsChannelID, ReliabilityError] =
  ## For extraction of channel ID without full message deserialization
  try:
    let pb = initProtoBuffer(data)
    var channelId: SdsChannelID
    let fieldOk = pb.getField(4, channelId).valueOr:
      return err(ReliabilityError.reDeserializationError)
    if not fieldOk:
      return err(ReliabilityError.reDeserializationError)
    ok(channelId)
  except:
    err(ReliabilityError.reDeserializationError)

proc serializeMessage*(msg: SdsMessage): Result[seq[byte], ReliabilityError] =
  let pb = encode(msg)
  ok(pb.buffer)

proc deserializeMessage*(data: seq[byte]): Result[SdsMessage, ReliabilityError] =
  let msg = SdsMessage.decode(data).valueOr:
    return err(ReliabilityError.reDeserializationError)
  ok(msg)

proc serializeBloomFilter*(filter: BloomFilter): Result[seq[byte], ReliabilityError] =
  var pb = initProtoBuffer()

  # Convert intArray to bytes
  try:
    var bytes = newSeq[byte](filter.intArray.len * sizeof(int))
    for i, val in filter.intArray:
      var leVal: int
      littleEndian64(addr leVal, unsafeAddr val)
      let start = i * sizeof(int)
      copyMem(addr bytes[start], addr leVal, sizeof(int))

    pb.write(1, bytes)
    pb.write(2, uint64(filter.capacity))
    pb.write(3, uint64(filter.errorRate * 1_000_000))
    pb.write(4, uint64(filter.kHashes))
    pb.write(5, uint64(filter.mBits))
  except:
    return err(ReliabilityError.reSerializationError)

  pb.finish()
  ok(pb.buffer)

proc deserializeBloomFilter*(data: seq[byte]): Result[BloomFilter, ReliabilityError] =
  if data.len == 0:
    return err(ReliabilityError.reDeserializationError)

  let pb = initProtoBuffer(data)
  var bytes: seq[byte]
  var cap, errRate, kHashes, mBits: uint64

  try:
    let
      field1_Ok = pb.getField(1, bytes).valueOr:
        return err(ReliabilityError.reDeserializationError)
      field2_Ok = pb.getField(2, cap).valueOr:
        return err(ReliabilityError.reDeserializationError)
      field3_Ok = pb.getField(3, errRate).valueOr:
        return err(ReliabilityError.reDeserializationError)
      field4_Ok = pb.getField(4, kHashes).valueOr:
        return err(ReliabilityError.reDeserializationError)
      field5_Ok = pb.getField(5, mBits).valueOr:
        return err(ReliabilityError.reDeserializationError)

    if not field1_Ok or not field2_Ok or not field3_Ok or not field4_Ok or not field5_Ok:
      return err(ReliabilityError.reDeserializationError)

    # Convert bytes back to intArray
    var intArray = newSeq[int](bytes.len div sizeof(int))
    for i in 0 ..< intArray.len:
      var leVal: int
      let start = i * sizeof(int)
      copyMem(addr leVal, unsafeAddr bytes[start], sizeof(int))
      littleEndian64(addr intArray[i], addr leVal)

    ok(
      BloomFilter(
        intArray: intArray,
        capacity: int(cap),
        errorRate: float(errRate) / 1_000_000,
        kHashes: int(kHashes),
        mBits: int(mBits),
      )
    )
  except:
    return err(ReliabilityError.reDeserializationError)

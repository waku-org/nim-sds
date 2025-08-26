import libp2p/protobuf/minprotobuf
import std/options
import endians
import ./[message, protobufutil, bloom, reliability_utils]

proc encode*(msg: SdsMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.messageId)
  pb.write(2, uint64(msg.lamportTimestamp))

  for hist in msg.causalHistory:
    pb.write(3, hist)

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

  var causalHistory: seq[SdsMessageID]
  let histResult = pb.getRepeatedField(3, causalHistory)
  if histResult.isOk:
    msg.causalHistory = causalHistory

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
    if not pb.getField(4, channelId).get():
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
    if not pb.getField(1, bytes).get() or not pb.getField(2, cap).get() or
        not pb.getField(3, errRate).get() or not pb.getField(4, kHashes).get() or
        not pb.getField(5, mBits).get():
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

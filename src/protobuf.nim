import libp2p/protobuf/minprotobuf
import std/options
import ../src/[message, protobufutil, bloom, reliability_utils]

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  copyMem(result[0].addr, s[0].unsafeAddr, s.len)

proc encode*(msg: Message): ProtoBuffer =
  var pb = initProtoBuffer()
  
  pb.write(1, msg.messageId) 
  pb.write(2, uint64(msg.lamportTimestamp))

  for hist in msg.causalHistory:
    pb.write(3, hist.toBytes)  # Convert string to bytes for proper length handling

  pb.write(4, msg.channelId)
  pb.write(5, msg.content)
  pb.write(6, msg.bloomFilter)
  pb.finish()
  
  pb

proc decode*(T: type Message, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var msg = Message()

  if not ?pb.getField(1, msg.messageId):
    return err(ProtobufError.missingRequiredField("messageId"))

  var timestamp: uint64
  if not ?pb.getField(2, timestamp):
    return err(ProtobufError.missingRequiredField("lamportTimestamp"))
  msg.lamportTimestamp = int64(timestamp)

  # Decode causal history
  var causalHistory: seq[string]
  let histResult = pb.getRepeatedField(3, causalHistory)
  if histResult.isOk:
    msg.causalHistory = causalHistory

  if not ?pb.getField(4, msg.channelId):
    return err(ProtobufError.missingRequiredField("channelId"))

  if not ?pb.getField(5, msg.content):
    return err(ProtobufError.missingRequiredField("content"))

  if not ?pb.getField(6, msg.bloomFilter):
    msg.bloomFilter = @[]  # Empty if not present

  ok(msg)

proc serializeMessage*(msg: Message): Result[seq[byte], ReliabilityError] = 
  try:
    let pb = encode(msg)
    ok(pb.buffer)
  except:
    err(reSerializationError)

proc deserializeMessage*(data: seq[byte]): Result[Message, ReliabilityError] =
  try:
    let msgResult = Message.decode(data)
    if msgResult.isOk:
      ok(msgResult.get)
    else:
      err(reSerializationError)
  except:
    err(reDeserializationError)

proc serializeBloomFilter*(filter: BloomFilter): Result[seq[byte], ReliabilityError] =
  try:
    var pb = initProtoBuffer()
    
    # Convert intArray to bytes
    var bytes = newSeq[byte](filter.intArray.len * sizeof(int))
    for i, val in filter.intArray:
      let start = i * sizeof(int)
      copyMem(addr bytes[start], unsafeAddr val, sizeof(int))
    
    pb.write(1, bytes)
    pb.write(2, uint64(filter.capacity))
    pb.write(3, uint64(filter.errorRate * 1_000_000))
    pb.write(4, uint64(filter.kHashes))
    pb.write(5, uint64(filter.mBits))
    
    pb.finish()
    ok(pb.buffer)
  except:
    err(reSerializationError)

proc deserializeBloomFilter*(data: seq[byte]): Result[BloomFilter, ReliabilityError] =
  if data.len == 0:
    return err(reDeserializationError)
    
  try:
    let pb = initProtoBuffer(data)
    var bytes: seq[byte]
    var cap, errRate, kHashes, mBits: uint64
    
    if not pb.getField(1, bytes).get() or
       not pb.getField(2, cap).get() or
       not pb.getField(3, errRate).get() or
       not pb.getField(4, kHashes).get() or
       not pb.getField(5, mBits).get():
      return err(reDeserializationError)
    
    # Convert bytes back to intArray
    var intArray = newSeq[int](bytes.len div sizeof(int))
    for i in 0 ..< intArray.len:
      let start = i * sizeof(int)
      copyMem(addr intArray[i], unsafeAddr bytes[start], sizeof(int))
    
    ok(BloomFilter(
      intArray: intArray,
      capacity: int(cap),
      errorRate: float(errRate) / 1_000_000,
      kHashes: int(kHashes),
      mBits: int(mBits)
    ))
  except:
    err(reDeserializationError)
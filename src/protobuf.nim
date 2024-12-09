import ./protobufutil
import ./common
import libp2p/protobuf/minprotobuf
import std/options

proc toString(bytes: seq[byte]): string =
  result = newString(bytes.len)
  copyMem(result[0].addr, bytes[0].unsafeAddr, bytes.len)

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
  var histories: seq[seq[byte]]
  for histBytes in histories:
    let hist = histBytes.toString
    if hist notin msg.causalHistory:  # Avoid duplicate entries
      msg.causalHistory.add(hist)

  if not ?pb.getField(4, msg.channelId):
    return err(ProtobufError.missingRequiredField("channelId"))

  if not ?pb.getField(5, msg.content):
    return err(ProtobufError.missingRequiredField("content"))

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
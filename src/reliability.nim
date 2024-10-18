import std/[times, hashes, random, sequtils, algorithm]
import nimsha2
import chronicles

const
  BloomFilterSize = 10000
  BloomFilterHashCount = 7
  MaxMessageHistory = 100
  MaxCausalHistory = 10

type
  MessageID* = string

  Message* = object
    senderId*: string
    messageId*: MessageID
    lamportTimestamp*: int64
    causalHistory*: seq[MessageID]
    channelId*: string
    content*: string
    bloomFilter*: RollingBloomFilter

  UnacknowledgedMessage* = object
    message*: Message
    sendTime*: Time
    resendAttempts*: int

  RollingBloomFilter* = object
    # TODO: Implement a proper Bloom filter
    data: array[BloomFilterSize, bool]
    hashCount: int

  ReliabilityManager* = ref object
    lamportTimestamp: int64
    messageHistory: seq[MessageID]
    bloomFilter: RollingBloomFilter
    outgoingBuffer: seq[UnacknowledgedMessage]
    incomingBuffer: seq[Message]
    channelId: string
    onMessageReady*: proc(messageId: MessageID)
    onMessageSent*: proc(messageId: MessageID)
    onMissingDependencies*: proc(messageId: MessageID, missingDeps: seq[MessageID])

proc hash(filter: RollingBloomFilter): Hash =
  var h: Hash = 0
  for idx, val in filter.data:
    h = h !& hash(idx) !& hash(val)
  result = !$h

proc newRollingBloomFilter(): RollingBloomFilter =
  result.hashCount = BloomFilterHashCount

proc add(filter: var RollingBloomFilter, item: MessageID) =
  let itemHash = hash(item)
  for i in 0 ..< filter.hashCount:
    let idx = (itemHash + i * i) mod BloomFilterSize
    filter.data[idx] = true

proc contains(filter: RollingBloomFilter, item: MessageID): bool =
  let itemHash = hash(item)
  for i in 0 ..< filter.hashCount:
    let idx = (itemHash + i * i) mod BloomFilterSize
    if not filter.data[idx]:
      return false
  return true

proc newReliabilityManager*(channelId: string): ReliabilityManager =
  result = ReliabilityManager(
    lamportTimestamp: 0,
    messageHistory: @[],
    bloomFilter: newRollingBloomFilter(),
    outgoingBuffer: @[],
    incomingBuffer: @[],
    channelId: channelId
  )

proc generateUniqueID(): MessageID =
  $secureHash($getTime().toUnix & $rand(high(int)))

proc updateLamportTimestamp(rm: ReliabilityManager, msgTs: int64) =
  rm.lamportTimestamp = max(msgTs, rm.lamportTimestamp) + 1

proc getRecentMessageIDs(rm: ReliabilityManager, n: int): seq[MessageID] =
  result = rm.messageHistory[max(0, rm.messageHistory.len - n) .. ^1]

proc wrapOutgoingMessage*(rm: ReliabilityManager, message: string): Message =
  rm.updateLamportTimestamp(getTime().toUnix)
  let msg = Message(
    senderId: "TODO_SENDER_ID",
    messageId: generateUniqueID(),
    lamportTimestamp: rm.lamportTimestamp,
    causalHistory: rm.getRecentMessageIDs(MaxCausalHistory),
    channelId: rm.channelId,
    content: message,
    bloomFilter: rm.bloomFilter
  )
  rm.outgoingBuffer.add(UnacknowledgedMessage(message: msg, sendTime: getTime(), resendAttempts: 0))
  msg

proc unwrapReceivedMessage*(rm: ReliabilityManager, message: Message): tuple[message: Message, missingDeps: seq[MessageID]] =
  if rm.bloomFilter.contains(message.messageId):
    return (message, @[])

  rm.bloomFilter.add(message.messageId)
  rm.updateLamportTimestamp(message.lamportTimestamp)

  var missingDeps: seq[MessageID] = @[]
  for depId in message.causalHistory:
    if depId notin rm.messageHistory:
      missingDeps.add(depId)

  if missingDeps.len == 0:
    rm.messageHistory.add(message.messageId)
    if rm.messageHistory.len > MaxMessageHistory:
      rm.messageHistory.delete(0)
    if rm.onMessageReady != nil:
      rm.onMessageReady(message.messageId)
  else:
    rm.incomingBuffer.add(message)
    if rm.onMissingDependencies != nil:
      rm.onMissingDependencies(message.messageId, missingDeps)

  (message, missingDeps)

proc markDependenciesMet*(rm: ReliabilityManager, messageIds: seq[MessageID]) =
  var processedMessages: seq[Message] = @[]
  rm.incomingBuffer = rm.incomingBuffer.filterIt(
    not messageIds.allIt(it in it.causalHistory or it in rm.messageHistory)
  )

  for msg in processedMessages:
    rm.messageHistory.add(msg.messageId)
    if rm.messageHistory.len > MaxMessageHistory:
      rm.messageHistory.delete(0)
    if rm.onMessageReady != nil:
      rm.onMessageReady(msg.messageId)

proc checkUnacknowledgedMessages(rm: ReliabilityManager) =
  let now = getTime()
  var newOutgoingBuffer: seq[UnacknowledgedMessage] = @[]
  for msg in rm.outgoingBuffer:
    if (now - msg.sendTime).inSeconds < 60:
      newOutgoingBuffer.add(msg)
    elif rm.onMessageSent != nil:
      rm.onMessageSent(msg.message.messageId)
  rm.outgoingBuffer = newOutgoingBuffer

proc setCallbacks*(rm: ReliabilityManager, 
                   onMessageReady: proc(messageId: MessageID), 
                   onMessageSent: proc(messageId: MessageID),
                   onMissingDependencies: proc(messageId: MessageID, missingDeps: seq[MessageID])) =
  rm.onMessageReady = onMessageReady
  rm.onMessageSent = onMessageSent
  rm.onMissingDependencies = onMissingDependencies

# Logging
proc logInfo(msg: string) =
  info msg

proc logError(msg: string) =
  error msg

# Export C API
{.push exportc, cdecl.}

type
  CMessage {.bycopy.} = object
    senderId: cstring
    messageId: cstring
    lamportTimestamp: int64
    causalHistory: ptr UncheckedArray[cstring]
    causalHistoryLen: cint
    channelId: cstring
    content: cstring
    bloomFilter: pointer

  CUnwrapResult {.bycopy.} = object
    message: CMessage
    missingDeps: ptr UncheckedArray[cstring]
    missingDepsLen: cint

proc reliability_manager_new(channelId: cstring): pointer {.exportc, cdecl.} =
  let rm = newReliabilityManager($channelId)
  GC_ref(rm)
  result = cast[pointer](rm)

proc reliability_manager_free(rmPtr: pointer) {.exportc, cdecl.} =
  let rm = cast[ReliabilityManager](rmPtr)
  GC_unref(rm)

proc wrap_outgoing_message(rmPtr: pointer, message: cstring): CMessage {.exportc, cdecl.} =
  let rm = cast[ReliabilityManager](rmPtr)
  let wrappedMsg = rm.wrapOutgoingMessage($message)
  
  result.senderId = wrappedMsg.senderId.cstring
  result.messageId = wrappedMsg.messageId.cstring
  result.lamportTimestamp = wrappedMsg.lamportTimestamp
  result.causalHistory = cast[ptr UncheckedArray[cstring]](alloc0(wrappedMsg.causalHistory.len * sizeof(cstring)))
  result.causalHistoryLen = wrappedMsg.causalHistory.len.cint
  for i, id in wrappedMsg.causalHistory:
    result.causalHistory[i] = id.cstring
  result.channelId = wrappedMsg.channelId.cstring
  result.content = wrappedMsg.content.cstring
  result.bloomFilter = cast[pointer](addr wrappedMsg.bloomFilter)

proc unwrap_received_message(rmPtr: pointer, msg: CMessage): CUnwrapResult {.exportc, cdecl.} =
  let rm = cast[ReliabilityManager](rmPtr)
  var nimMsg = Message(
    senderId: $msg.senderId,
    messageId: $msg.messageId,
    lamportTimestamp: msg.lamportTimestamp,
    causalHistory: newSeq[string](msg.causalHistoryLen),
    channelId: $msg.channelId,
    content: $msg.content,
    bloomFilter: cast[RollingBloomFilter](msg.bloomFilter)[]
  )
  for i in 0 ..< msg.causalHistoryLen:
    nimMsg.causalHistory[i] = $msg.causalHistory[i]

  let (unwrappedMsg, missingDeps) = rm.unwrapReceivedMessage(nimMsg)
  
  result.message = CMessage(
    senderId: unwrappedMsg.senderId.cstring,
    messageId: unwrappedMsg.messageId.cstring,
    lamportTimestamp: unwrappedMsg.lamportTimestamp,
    causalHistory: cast[ptr UncheckedArray[cstring]](alloc0(unwrappedMsg.causalHistory.len * sizeof(cstring))),
    causalHistoryLen: unwrappedMsg.causalHistory.len.cint,
    channelId: unwrappedMsg.channelId.cstring,
    content: unwrappedMsg.content.cstring,
    bloomFilter: cast[pointer](addr unwrappedMsg.bloomFilter)
  )
  for i, id in unwrappedMsg.causalHistory:
    result.message.causalHistory[i] = id.cstring
  
  result.missingDeps = cast[ptr UncheckedArray[cstring]](alloc0(missingDeps.len * sizeof(cstring)))
  result.missingDepsLen = missingDeps.len.cint
  for i, id in missingDeps:
    result.missingDeps[i] = id.cstring

proc mark_dependencies_met(rmPtr: pointer, messageIds: ptr UncheckedArray[cstring], count: cint) {.exportc, cdecl.} =
  let rm = cast[ReliabilityManager](rmPtr)
  var nimMessageIds = newSeq[string](count)
  for i in 0 ..< count:
    nimMessageIds[i] = $messageIds[i]
  rm.markDependenciesMet(nimMessageIds)

proc set_callbacks(rmPtr: pointer, 
                   onMessageReady: proc(messageId: cstring) {.cdecl.},
                   onMessageSent: proc(messageId: cstring) {.cdecl.},
                   onMissingDependencies: proc(messageId: cstring, missingDeps: ptr UncheckedArray[cstring], missingDepsLen: cint) {.cdecl.}) {.exportc, cdecl.} =
  let rm = cast[ReliabilityManager](rmPtr)
  rm.setCallbacks(
    proc(messageId: MessageID) = onMessageReady(messageId.cstring),
    proc(messageId: MessageID) = onMessageSent(messageId.cstring),
    proc(messageId: MessageID, missingDeps: seq[MessageID]) =
      var cMissingDeps = cast[ptr UncheckedArray[cstring]](alloc0(missingDeps.len * sizeof(cstring)))
      for i, dep in missingDeps:
        cMissingDeps[i] = dep.cstring
      onMissingDependencies(messageId.cstring, cMissingDeps, missingDeps.len.cint)
      dealloc(cMissingDeps)
  )

{.pop.}

when isMainModule:
  # TODO: Add some basic tests / examples
  let rm = newReliabilityManager("testChannel")
  let msg = rm.wrapOutgoingMessage("Hello, World!")
  echo "Wrapped message: ", msg
  
  let (unwrappedMsg, missingDeps) = rm.unwrapReceivedMessage(msg)
  echo "Unwrapped message: ", unwrappedMsg
  echo "Missing dependencies: ", missingDeps
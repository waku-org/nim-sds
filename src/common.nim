import std/[times, json, locks]
import "../nim-bloom/src/bloom"

type
  MessageID* = string

  Message* = object
    senderId*: string
    messageId*: MessageID
    lamportTimestamp*: int64
    causalHistory*: seq[MessageID]
    channelId*: string
    content*: string

  UnacknowledgedMessage* = object
    message*: Message
    sendTime*: Time
    resendAttempts*: int

  TimestampedMessageID* = object
    id*: MessageID
    timestamp*: Time

  RollingBloomFilter* = object
    filter*: BloomFilter
    window*: Duration
    messages*: seq[TimestampedMessageID]

  ReliabilityConfig* = object
    bloomFilterCapacity*: int
    bloomFilterErrorRate*: float
    bloomFilterWindow*: Duration
    maxMessageHistory*: int
    maxCausalHistory*: int
    resendInterval*: Duration
    maxResendAttempts*: int

  ReliabilityManager* = ref object
    lamportTimestamp*: int64
    messageHistory*: seq[MessageID]
    bloomFilter*: RollingBloomFilter
    outgoingBuffer*: seq[UnacknowledgedMessage]
    incomingBuffer*: seq[Message]
    channelId*: string
    config*: ReliabilityConfig
    lock*: Lock
    onMessageReady*: proc(messageId: MessageID)
    onMessageSent*: proc(messageId: MessageID)
    onMissingDependencies*: proc(messageId: MessageID, missingDeps: seq[MessageID])

  ReliabilityError* = enum
    reSuccess,
    reInvalidArgument,
    reOutOfMemory,
    reInternalError,
    reSerializationError,
    reDeserializationError,
    reMessageTooLarge

  Result*[T] = object
    case isOk*: bool
    of true:
      value*: T
    of false:
      error*: ReliabilityError

const
  DefaultBloomFilterCapacity* = 10000
  DefaultBloomFilterErrorRate* = 0.001
  DefaultBloomFilterWindow* = initDuration(hours = 1)
  DefaultMaxMessageHistory* = 1000
  DefaultMaxCausalHistory* = 10
  DefaultResendInterval* = initDuration(seconds = 30)
  DefaultMaxResendAttempts* = 5
  MaxMessageSize* = 1024 * 1024  # 1 MB

proc ok*[T](value: T): Result[T] =
  Result[T](isOk: true, value: value)

proc err*[T](error: ReliabilityError): Result[T] =
  Result[T](isOk: false, error: error)
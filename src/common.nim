import std/[times, locks]
import "../nim-bloom/src/bloom"

type
  MessageID* = string

  Message* = object
    messageId*: MessageID
    lamportTimestamp*: int64
    causalHistory*: seq[MessageID]
    channelId*: string
    content*: seq[byte]
    bloomFilter*: seq[byte]

  UnacknowledgedMessage* = object
    message*: Message
    sendTime*: Time
    resendAttempts*: int

  TimestampedMessageID* = object
    id*: MessageID
    timestamp*: Time

  PeriodicSyncCallback* = proc() {.gcsafe, raises: [].}

  RollingBloomFilter* = object
    filter*: BloomFilter
    window*: times.Duration
    messages*: seq[TimestampedMessageID]

  ReliabilityConfig* = object
    bloomFilterCapacity*: int
    bloomFilterErrorRate*: float
    bloomFilterWindow*: times.Duration
    maxMessageHistory*: int
    maxCausalHistory*: int
    resendInterval*: times.Duration
    maxResendAttempts*: int
    syncMessageInterval*: times.Duration
    bufferSweepInterval*: times.Duration

  ReliabilityManager* = ref object
    lamportTimestamp*: int64
    messageHistory*: seq[MessageID]
    bloomFilter*: RollingBloomFilter
    outgoingBuffer*: seq[UnacknowledgedMessage]
    incomingBuffer*: seq[Message]
    channelId*: string
    config*: ReliabilityConfig
    lock*: Lock
    onMessageReady*: proc(messageId: MessageID) {.gcsafe.}
    onMessageSent*: proc(messageId: MessageID) {.gcsafe.}
    onMissingDependencies*: proc(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe.}
    onPeriodicSync*: PeriodicSyncCallback

  ReliabilityError* = enum
    reInvalidArgument
    reOutOfMemory
    reInternalError
    reSerializationError
    reDeserializationError
    reMessageTooLarge

const
  DefaultBloomFilterCapacity* = 10000
  DefaultBloomFilterErrorRate* = 0.001
  DefaultBloomFilterWindow* = initDuration(hours = 1)
  DefaultMaxMessageHistory* = 1000
  DefaultMaxCausalHistory* = 10
  DefaultResendInterval* = initDuration(seconds = 60)
  DefaultMaxResendAttempts* = 5
  DefaultSyncMessageInterval* = initDuration(seconds = 30)
  DefaultBufferSweepInterval* = initDuration(seconds = 60)
  MaxMessageSize* = 1024 * 1024  # 1 MB
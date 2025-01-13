import std/times

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

const
  DefaultMaxMessageHistory* = 1000
  DefaultMaxCausalHistory* = 10
  DefaultResendInterval* = initDuration(seconds = 60)
  DefaultMaxResendAttempts* = 5
  DefaultSyncMessageInterval* = initDuration(seconds = 30)
  DefaultBufferSweepInterval* = initDuration(seconds = 60)
  MaxMessageSize* = 1024 * 1024  # 1 MB
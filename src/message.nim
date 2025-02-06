import std/times

type
  MessageID* = seq[byte]
  ChannelID* = seq[byte]

  Message* = object
    messageId*: MessageID
    lamportTimestamp*: int64
    causalHistory*: seq[MessageID]
    channelId*: ChannelID
    content*: seq[byte]
    bloomFilter*: seq[byte]

  UnacknowledgedMessage* = object
    message*: Message
    sendTime*: Time
    resendAttempts*: int

const
  DefaultMaxMessageHistory* = 1000
  DefaultMaxCausalHistory* = 10
  DefaultResendInterval* = initDuration(seconds = 60)
  DefaultMaxResendAttempts* = 5
  DefaultSyncMessageInterval* = initDuration(seconds = 30)
  DefaultBufferSweepInterval* = initDuration(seconds = 60)
  MaxMessageSize* = 1024 * 1024  # 1 MB
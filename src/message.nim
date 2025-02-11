import std/times

type
  SdsMessageID* = seq[byte]
  SdsChannelID* = seq[byte]

  SdsMessage* = object
    messageId*: SdsMessageID
    lamportTimestamp*: int64
    causalHistory*: seq[SdsMessageID]
    channelId*: SdsChannelID
    content*: seq[byte]
    bloomFilter*: seq[byte]

  UnacknowledgedMessage* = object
    message*: SdsMessage
    sendTime*: Time
    resendAttempts*: int

const
  DefaultMaxMessageHistory* = 1000
  DefaultMaxCausalHistory* = 10
  DefaultResendInterval* = initDuration(seconds = 60)
  DefaultMaxResendAttempts* = 5
  DefaultSyncMessageInterval* = initDuration(seconds = 30)
  DefaultBufferSweepInterval* = initDuration(seconds = 60)
  MaxMessageSize* = 1024 * 1024 # 1 MB

import std/[times, sets]

type
  SdsMessageID* = string
  SdsChannelID* = string

  HistoryEntry* = object
    messageId*: SdsMessageID
    retrievalHint*: seq[byte]  ## Optional hint for efficient retrieval (e.g., Waku message hash)

  SdsMessage* = object
    messageId*: SdsMessageID
    lamportTimestamp*: int64
    causalHistory*: seq[HistoryEntry]
    channelId*: SdsChannelID
    content*: seq[byte]
    bloomFilter*: seq[byte]

  UnacknowledgedMessage* = object
    message*: SdsMessage
    sendTime*: Time
    resendAttempts*: int

  IncomingMessage* = object
    message*: SdsMessage
    missingDeps*: HashSet[SdsMessageID]

const
  DefaultMaxMessageHistory* = 1000
  DefaultMaxCausalHistory* = 10
  DefaultResendInterval* = initDuration(seconds = 60)
  DefaultMaxResendAttempts* = 5
  DefaultSyncMessageInterval* = initDuration(seconds = 30)
  DefaultBufferSweepInterval* = initDuration(seconds = 60)
  MaxMessageSize* = 1024 * 1024 # 1 MB

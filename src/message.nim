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

# Helper functions for HistoryEntry
proc newHistoryEntry*(messageId: SdsMessageID, retrievalHint: seq[byte] = @[]): HistoryEntry =
  ## Creates a new HistoryEntry with optional retrieval hint
  HistoryEntry(messageId: messageId, retrievalHint: retrievalHint)

proc newHistoryEntry*(messageId: SdsMessageID, retrievalHint: string): HistoryEntry =
  ## Creates a new HistoryEntry with string retrieval hint
  HistoryEntry(messageId: messageId, retrievalHint: cast[seq[byte]](retrievalHint))

proc toCausalHistory*(messageIds: seq[SdsMessageID]): seq[HistoryEntry] =
  ## Converts a sequence of message IDs to HistoryEntry sequence (for backward compatibility)
  result = newSeq[HistoryEntry](messageIds.len)
  for i, msgId in messageIds:
    result[i] = newHistoryEntry(msgId)

proc getMessageIds*(causalHistory: seq[HistoryEntry]): seq[SdsMessageID] =
  ## Extracts message IDs from HistoryEntry sequence
  result = newSeq[SdsMessageID](causalHistory.len)
  for i, entry in causalHistory:
    result[i] = entry.messageId

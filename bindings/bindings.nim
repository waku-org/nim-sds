import genny
import std/[times, strutils]
import results
import ../src/[reliability, message, reliability_utils, rolling_bloom_filter]

# Define required sequence wrapper types for C FFI
type
  SeqByte* = ref object
    s*: seq[byte]
  
  SeqMessageID* = ref object
    s*: seq[MessageID]
  
  SeqMessage* = ref object
    s*: seq[Message]
  
  SeqUnacknowledgedMessage* = ref object
    s*: seq[UnacknowledgedMessage]

# Error handling
var lastError: ReliabilityError

proc takeError(): string =
  result = $lastError
  lastError = ReliabilityError.reInternalError  # Reset to default

proc checkError(): bool =
  result = lastError != ReliabilityError.reInternalError

# Callback function types for C FFI
type
  CMessageReadyCallback* = proc(messageId: cstring) {.cdecl, gcsafe.}
  CMessageSentCallback* = proc(messageId: cstring) {.cdecl, gcsafe.}
  CMissingDepsCallback* = proc(messageId: cstring, missingDeps: cstring, count: cint) {.cdecl, gcsafe.}
  CPeriodicSyncCallback* = proc() {.cdecl, gcsafe.}

# Global callback storage
var
  onMessageReadyCallback: CMessageReadyCallback
  onMessageSentCallback: CMessageSentCallback
  onMissingDepsCallback: CMissingDepsCallback
  onPeriodicSyncCallback: CPeriodicSyncCallback

# Register callbacks
proc registerMessageReadyCallback*(callback: CMessageReadyCallback) =
  onMessageReadyCallback = callback

proc registerMessageSentCallback*(callback: CMessageSentCallback) =
  onMessageSentCallback = callback

proc registerMissingDepsCallback*(callback: CMissingDepsCallback) =
  onMissingDepsCallback = callback

proc registerPeriodicSyncCallback*(callback: CPeriodicSyncCallback) =
  onPeriodicSyncCallback = callback

# Individual adapter functions
proc onMessageReadyAdapter(messageId: MessageID) {.gcsafe, raises: [].} =
  if onMessageReadyCallback != nil:
    try:
      onMessageReadyCallback(cstring(messageId))
    except:
      discard # Ignore exceptions

proc onMessageSentAdapter(messageId: MessageID) {.gcsafe, raises: [].} =
  if onMessageSentCallback != nil:
    try:
      onMessageSentCallback(cstring(messageId))
    except:
      discard

proc onMissingDependenciesAdapter(messageId: MessageID, missingDeps: seq[MessageID]) {.gcsafe, raises: [].} =
  if onMissingDepsCallback != nil and missingDeps.len > 0:
    try:
      let joinedDeps = missingDeps.join(",")
      onMissingDepsCallback(cstring(messageId), cstring(joinedDeps), cint(missingDeps.len))
    except:
      discard

proc onPeriodicSyncAdapter() {.gcsafe, raises: [].} =
  if onPeriodicSyncCallback != nil:
    try:
      onPeriodicSyncCallback()
    except:
      discard

# Apply registered callbacks to a ReliabilityManager
proc applyCallbacks*(rm: ReliabilityManager): bool =
  if rm == nil:
    lastError = ReliabilityError.reInvalidArgument
    return false
  
  try:
    rm.setCallbacks(
      onMessageReadyAdapter,
      onMessageSentAdapter,
      onMissingDependenciesAdapter,
      onPeriodicSyncAdapter
    )
    return true
  except:
    lastError = ReliabilityError.reInternalError
    return false

# Wrapper for creating a ReliabilityManager
proc safeNewReliabilityManager(channelId: string, config: ReliabilityConfig = defaultConfig()): ReliabilityManager =
  let res = newReliabilityManager(channelId, config)
  if res.isOk:
    return res.get
  else:
    lastError = res.error
    return nil

# Wrapper for wrapping outgoing messages
proc safeWrapOutgoingMessage(rm: ReliabilityManager, message: seq[byte], messageId: MessageID): seq[byte] =
  if rm == nil:
    lastError = ReliabilityError.reInvalidArgument
    return @[]
  
  let res = rm.wrapOutgoingMessage(message, messageId)
  if res.isOk:
    return res.get
  else:
    lastError = res.error
    return @[]

# Wrapper for unwrapping received messages
proc safeUnwrapReceivedMessage(rm: ReliabilityManager, message: seq[byte]): tuple[message: seq[byte], missingDeps: seq[MessageID]] =
  if rm == nil:
    lastError = ReliabilityError.reInvalidArgument
    return (@[], @[])
  
  let res = rm.unwrapReceivedMessage(message)
  if res.isOk:
    return res.get
  else:
    lastError = res.error
    return (@[], @[])

# Wrapper for marking dependencies as met
proc safeMarkDependenciesMet(rm: ReliabilityManager, messageIds: seq[MessageID]): bool =
  if rm == nil:
    lastError = ReliabilityError.reInvalidArgument
    return false
  
  let res = rm.markDependenciesMet(messageIds)
  if res.isOk:
    return true
  else:
    lastError = res.error
    return false

# Helper to create a Duration from milliseconds
proc durationFromMs(ms: int64): Duration =
  initDuration(milliseconds = ms)

# Wrapper for creating a ReliabilityConfig with Duration values in milliseconds
proc configFromMs(
  bloomFilterCapacity: int = DefaultBloomFilterCapacity,
  bloomFilterErrorRate: float = DefaultBloomFilterErrorRate,
  bloomFilterWindowMs: int64 = 3600000, # 1 hour default
  maxMessageHistory: int = DefaultMaxMessageHistory,
  maxCausalHistory: int = DefaultMaxCausalHistory,
  resendIntervalMs: int64 = 60000, # 1 minute default
  maxResendAttempts: int = DefaultMaxResendAttempts,
  syncMessageIntervalMs: int64 = 30000, # 30 seconds default
  bufferSweepIntervalMs: int64 = 60000 # 1 minute default
): ReliabilityConfig =
  var config = ReliabilityConfig(
    bloomFilterCapacity: bloomFilterCapacity,
    bloomFilterErrorRate: bloomFilterErrorRate,
    bloomFilterWindow: durationFromMs(bloomFilterWindowMs),
    maxMessageHistory: maxMessageHistory,
    maxCausalHistory: maxCausalHistory,
    resendInterval: durationFromMs(resendIntervalMs),
    maxResendAttempts: maxResendAttempts,
    syncMessageInterval: durationFromMs(syncMessageIntervalMs),
    bufferSweepInterval: durationFromMs(bufferSweepIntervalMs)
  )
  return config

# Helper to parse comma-separated string into seq[MessageID]
proc parseMessageIDs*(commaSeparated: string): seq[MessageID] =
  if commaSeparated.len == 0:
    return @[]
  return commaSeparated.split(',')

# Constants
exportConsts:
  DefaultBloomFilterCapacity
  DefaultBloomFilterErrorRate
  DefaultMaxMessageHistory
  DefaultMaxCausalHistory
  DefaultMaxResendAttempts
  MaxMessageSize

# Enums
exportEnums:
  ReliabilityError

# Helper procs
exportProcs:
  checkError
  takeError
  configFromMs
  durationFromMs
  parseMessageIDs
  registerMessageReadyCallback
  registerMessageSentCallback
  registerMissingDepsCallback
  registerPeriodicSyncCallback
  applyCallbacks

# Core objects
exportObject ReliabilityConfig:
  constructor:
    configFromMs(int, float, int64, int, int, int64, int, int64, int64)

# Main ref object
exportRefObject ReliabilityManager:
  constructor:
    safeNewReliabilityManager(string, ReliabilityConfig)
  procs:
    safeWrapOutgoingMessage(ReliabilityManager, seq[byte], MessageID)
    safeUnwrapReceivedMessage(ReliabilityManager, seq[byte])
    safeMarkDependenciesMet(ReliabilityManager, seq[MessageID])
    checkUnacknowledgedMessages(ReliabilityManager)
    startPeriodicTasks(ReliabilityManager)
    cleanup(ReliabilityManager)
    getMessageHistory(ReliabilityManager)
    getOutgoingBuffer(ReliabilityManager)
    getIncomingBuffer(ReliabilityManager)

# Sequences
exportSeq seq[byte]:
  discard

exportSeq seq[MessageID]:
  discard

# Finally generate the files
writeFiles("bindings/generated", "sds_bindings")
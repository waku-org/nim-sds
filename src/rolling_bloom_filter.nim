import std/times
import chronos
import chronicles
import ./[bloom, message]

type
  RollingBloomFilter* = object
    filter*: BloomFilter
    window*: times.Duration
    messages*: seq[TimestampedMessageID]

const
  DefaultBloomFilterCapacity* = 10000
  DefaultBloomFilterErrorRate* = 0.001
  DefaultBloomFilterWindow* = initDuration(hours = 1)

proc logError*(msg: string) =
  error "ReliabilityError", message = msg

proc logInfo*(msg: string) =
  info "ReliabilityInfo", message = msg

proc newRollingBloomFilter*(capacity: int, errorRate: float, window: times.Duration): RollingBloomFilter {.gcsafe.} =
  try:
    var filterResult: Result[BloomFilter, string]
    {.gcsafe.}:
      filterResult = initializeBloomFilter(capacity, errorRate)
    
    if filterResult.isOk:
      logInfo("Successfully initialized bloom filter")
      return RollingBloomFilter(
        filter: filterResult.get(), # Extract the BloomFilter from Result
        window: window,
        messages: @[]
      )
    else:
      logError("Failed to initialize bloom filter: " & filterResult.error)
      # Fall through to default case below
    
  except:
    logError("Failed to initialize bloom filter")
    
  # Default fallback case
  let defaultResult = initializeBloomFilter(DefaultBloomFilterCapacity, DefaultBloomFilterErrorRate)
  if defaultResult.isOk:
    return RollingBloomFilter(
      filter: defaultResult.get(),
      window: window,
      messages: @[]
    )
  else:
    # If even default initialization fails, raise an exception
    logError("Failed to initialize bloom filter with default parameters")

proc add*(rbf: var RollingBloomFilter, messageId: MessageID) {.gcsafe.} =
  ## Adds a message ID to the rolling bloom filter.
  ##
  ## Parameters:
  ##   - messageId: The ID of the message to add.
  rbf.filter.insert(messageId)
  rbf.messages.add(TimestampedMessageID(id: messageId, timestamp: getTime()))

proc contains*(rbf: RollingBloomFilter, messageId: MessageID): bool {.gcsafe.} =
  ## Checks if a message ID is in the rolling bloom filter.
  ##
  ## Parameters:
  ##   - messageId: The ID of the message to check.
  ##
  ## Returns:
  ##   True if the message ID is probably in the filter, false otherwise.
  rbf.filter.lookup(messageId)

proc clean*(rbf: var RollingBloomFilter) {.gcsafe.} =
  try:
    let now = getTime()
    let cutoff = now - rbf.window
    var newMessages: seq[TimestampedMessageID] = @[]
    
    # Initialize new filter
    let newFilterResult = initializeBloomFilter(rbf.filter.capacity, rbf.filter.errorRate)
    if newFilterResult.isErr:
      logError("Failed to create new bloom filter: " & newFilterResult.error)
      return

    var newFilter = newFilterResult.get()

    for msg in rbf.messages:
      if msg.timestamp > cutoff:
        newMessages.add(msg)
        newFilter.insert(msg.id)

    rbf.messages = newMessages
    rbf.filter = newFilter
  except Exception as e:
    logError("Failed to clean bloom filter: " & e.msg)
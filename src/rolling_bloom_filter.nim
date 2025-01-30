import chronos
import chronicles
import ./[bloom, message]

type
  RollingBloomFilter* = object
    filter*: BloomFilter
    capacity*: int
    minCapacity*: int
    maxCapacity*: int
    messages*: seq[MessageID]

const
  DefaultBloomFilterCapacity* = 10000
  DefaultBloomFilterErrorRate* = 0.001
  CapacityFlexPercent* = 20

proc logError*(msg: string) =
  error "ReliabilityError", message = msg

proc logInfo*(msg: string) =
  info "ReliabilityInfo", message = msg

proc newRollingBloomFilter*(capacity: int, errorRate: float): RollingBloomFilter {.gcsafe.} =
  try:
    var filterResult: Result[BloomFilter, string]
    {.gcsafe.}:
      filterResult = initializeBloomFilter(capacity, errorRate)
    
    if filterResult.isOk:
      logInfo("Successfully initialized bloom filter")
      let targetCapacity = capacity
      let minCapacity = (capacity.float * 0.8).int
      let maxCapacity = (capacity.float * 1.2).int
      return RollingBloomFilter(
        filter: filterResult.get(),
        capacity: targetCapacity,
        minCapacity: minCapacity,
        maxCapacity: maxCapacity,
        messages: @[]
      )
    else:
      logError("Failed to initialize bloom filter: " & filterResult.error)
    
  except Exception:
    logError("Failed to initialize bloom filter: " & getCurrentExceptionMsg())
  
  # Default fallback case
  let defaultResult = initializeBloomFilter(DefaultBloomFilterCapacity, DefaultBloomFilterErrorRate)
  if defaultResult.isOk:
    return RollingBloomFilter(
      filter: defaultResult.get(),
      capacity: DefaultBloomFilterCapacity,
      minCapacity: (DefaultBloomFilterCapacity.float * 0.8).int,
      maxCapacity: (DefaultBloomFilterCapacity.float * 1.2).int,
      messages: @[]
    )
  else:
    logError("Failed to initialize bloom filter with default parameters: " & defaultResult.error)

proc clean*(rbf: var RollingBloomFilter) {.gcsafe.} =
  try:
    if rbf.messages.len <= rbf.maxCapacity:
      return # Don't clean unless we exceed max capacity
      
    # Initialize new filter
    let newFilterResult = initializeBloomFilter(rbf.maxCapacity, rbf.filter.errorRate)
    if newFilterResult.isErr:
      logError("Failed to create new bloom filter: " & newFilterResult.error)
      return

    var newFilter = newFilterResult.get()
    
    # Keep most recent messages up to minCapacity
    let keepCount = rbf.minCapacity
    let startIdx = max(0, rbf.messages.len - keepCount)
    var newMessages: seq[MessageID] = @[]
    
    for i in startIdx ..< rbf.messages.len:
      newMessages.add(rbf.messages[i])
      newFilter.insert(rbf.messages[i])

    rbf.messages = newMessages
    rbf.filter = newFilter

  except Exception:
    logError("Failed to clean bloom filter: " & getCurrentExceptionMsg())

proc add*(rbf: var RollingBloomFilter, messageId: MessageID) {.gcsafe.} =
  ## Adds a message ID to the rolling bloom filter.
  ##
  ## Parameters:
  ##   - messageId: The ID of the message to add.
  rbf.filter.insert(messageId)
  rbf.messages.add(messageId)
  
  # Clean if we exceed max capacity
  if rbf.messages.len > rbf.maxCapacity:
    rbf.clean()

proc contains*(rbf: RollingBloomFilter, messageId: MessageID): bool {.gcsafe.} =
  ## Checks if a message ID is in the rolling bloom filter.
  ##
  ## Parameters:
  ##   - messageId: The ID of the message to check.
  ##
  ## Returns:
  ##   True if the message ID is probably in the filter, false otherwise.
  rbf.filter.lookup(messageId)
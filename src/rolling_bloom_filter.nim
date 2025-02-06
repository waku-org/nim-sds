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

proc newRollingBloomFilter*(capacity: int = DefaultBloomFilterCapacity, 
                          errorRate: float = DefaultBloomFilterErrorRate): RollingBloomFilter {.gcsafe.} =
  let targetCapacity = if capacity <= 0: DefaultBloomFilterCapacity else: capacity
  let targetError = if errorRate <= 0.0 or errorRate >= 1.0: DefaultBloomFilterErrorRate else: errorRate
  
  let filterResult = initializeBloomFilter(targetCapacity, targetError)
  if filterResult.isErr:
    error "Failed to initialize bloom filter", error = filterResult.error
    # Try with default values if custom values failed
    if capacity != DefaultBloomFilterCapacity or errorRate != DefaultBloomFilterErrorRate:
      let defaultResult = initializeBloomFilter(DefaultBloomFilterCapacity, DefaultBloomFilterErrorRate)
      if defaultResult.isErr:
        error "Failed to initialize bloom filter with default parameters", error = defaultResult.error
      
      let minCapacity = (DefaultBloomFilterCapacity.float * (100 - CapacityFlexPercent).float / 100.0).int
      let maxCapacity = (DefaultBloomFilterCapacity.float * (100 + CapacityFlexPercent).float / 100.0).int
      
      info "Successfully initialized bloom filter with default parameters", 
           capacity = DefaultBloomFilterCapacity, 
           minCapacity = minCapacity, 
           maxCapacity = maxCapacity

      return RollingBloomFilter(
        filter: defaultResult.get(),
        capacity: DefaultBloomFilterCapacity,
        minCapacity: minCapacity,
        maxCapacity: maxCapacity,
        messages: @[]
      )
    else:
      error "Could not create bloom filter", error = filterResult.error

  let minCapacity = (targetCapacity.float * (100 - CapacityFlexPercent).float / 100.0).int
  let maxCapacity = (targetCapacity.float * (100 + CapacityFlexPercent).float / 100.0).int
  
  info "Successfully initialized bloom filter", 
       capacity = targetCapacity, 
       minCapacity = minCapacity, 
       maxCapacity = maxCapacity

  return RollingBloomFilter(
    filter: filterResult.get(),
    capacity: targetCapacity,
    minCapacity: minCapacity,
    maxCapacity: maxCapacity,
    messages: @[]
  )

proc clean*(rbf: var RollingBloomFilter) {.gcsafe.} =
  try:
    if rbf.messages.len <= rbf.maxCapacity:
      return # Don't clean unless we exceed max capacity
      
    # Initialize new filter
    let newFilterResult = initializeBloomFilter(rbf.maxCapacity, rbf.filter.errorRate)
    if newFilterResult.isErr:
      error "Failed to create new bloom filter", error = newFilterResult.error
      return

    var newFilter = newFilterResult.get()
    
    # Keep most recent messages up to minCapacity
    let keepCount = rbf.minCapacity
    let startIdx = max(0, rbf.messages.len - keepCount)
    var newMessages: seq[MessageID] = @[]
    
    for i in startIdx ..< rbf.messages.len:
      newMessages.add(rbf.messages[i])
      newFilter.insert(cast[string](rbf.messages[i]))

    rbf.messages = newMessages
    rbf.filter = newFilter

  except Exception:
    error "Failed to clean bloom filter", error = getCurrentExceptionMsg()

proc add*(rbf: var RollingBloomFilter, messageId: MessageID) {.gcsafe.} =
  ## Adds a message ID to the rolling bloom filter.
  ##
  ## Parameters:
  ##   - messageId: The ID of the message to add.
  rbf.filter.insert(cast[string](messageId))
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
  rbf.filter.lookup(cast[string](messageId))
import times, random, strutils
include bloom

type
  DataPattern = enum
    dpRandom,      # Random strings
    dpSequential,  # Sequential numbers
    dpFixed,       # Fixed length strings
    dpLong,        # Long strings
    dpSpecial      # Strings with special characters

type 
  BenchmarkResult = tuple[
    insertTime: float,
    lookupTime: float, 
    falsePositives: int
  ]

proc generateBenchData(pattern: DataPattern, size: int, isLookupData: bool = false): seq[string] =
  result = newSeq[string](size)
  let offset = if isLookupData: size * 2 else: 0  # Ensure lookup data is well separated
  
  case pattern:
  of dpRandom:
    for i in 0..<size:
      var s = ""
      for j in 0..rand(5..15):
        s.add(chr(rand(ord('a')..ord('z'))))
      result[i] = s
  of dpSequential:
    for i in 0..<size:
      result[i] = $(i + offset)  # Add offset for lookup data
  of dpFixed:
    for i in 0..<size:
      result[i] = "fixed" & align($(i + offset), 10, '0')
  of dpLong:
    for i in 0..<size:
      result[i] = repeat("x", 100) & $(i + offset)
  of dpSpecial:
    for i in 0..<size:
      result[i] = "test@" & $(i + offset) & "#$%^&*" & $rand(1000)

proc benchmarkHashType(hashType: HashType, size: int, errorRate: float, 
                      data: seq[string], lookupData: seq[string]): BenchmarkResult =
  # Initialize Bloom filter and run benchmark for given hash type
  var bf = initializeBloomFilter(size, errorRate, hashType = hashType)
  
  # Measure insert time
  let startInsert = cpuTime()
  for item in data:
    bf.insert(item)
  let insertTime = cpuTime() - startInsert
  
  # Measure lookup time and count false positives  
  var falsePositives = 0
  let startLookup = cpuTime()
  for item in lookupData:
    if bf.lookup(item): falsePositives.inc
  let lookupTime = cpuTime() - startLookup

  result = (insertTime, lookupTime, falsePositives)

proc printResults(hashName: string, result: BenchmarkResult, 
                 dataSize: int, lookupDataSize: int) =
  echo "\n", hashName, " Results:"
  echo "  Insert time: ", result.insertTime, "s (", dataSize.float/result.insertTime, " ops/sec)"
  echo "  Lookup time: ", result.lookupTime, "s (", lookupDataSize.float/result.lookupTime, " ops/sec)"
  echo "  False positives: ", result.falsePositives, " (", 
       result.falsePositives.float / lookupDataSize.float * 100, "%)"

proc runBenchmark(size: int, errorRate: float, pattern: DataPattern, name: string) =
  echo "\n=== Benchmark: ", name, " ==="
  echo "Size: ", size, " items"
  echo "Pattern: ", pattern
  
  # Generate test data
  let data = generateBenchData(pattern, size, false)
  let lookupData = generateBenchData(pattern, size div 2, true)
  
  # Run benchmarks for each hash type
  let nimHashResult = benchmarkHashType(htNimHash, size, errorRate, data, lookupData)
  let murmur128Result = benchmarkHashType(htMurmur128, size, errorRate, data, lookupData)
  let murmur32Result = benchmarkHashType(htMurmur32, size, errorRate, data, lookupData)
  
  # Print individual results
  printResults("Nim's Hash (Farm Hash)", nimHashResult, size, lookupData.len)
  printResults("MurmurHash3_128", murmur128Result, size, lookupData.len)
  printResults("MurmurHash3_32", murmur32Result, size, lookupData.len)
  
  # Print comparisons
  echo "\nComparison (higher means better/faster):"
  echo "  Insert Speed:"
  echo "    Murmur128 vs NimHash: ", nimHashResult.insertTime/murmur128Result.insertTime, "x faster"
  echo "    Murmur32 vs NimHash: ", nimHashResult.insertTime/murmur32Result.insertTime, "x faster"
  echo "    Murmur128 vs Murmur32: ", murmur32Result.insertTime/murmur128Result.insertTime, "x faster"
  
  echo "  Lookup Speed:"
  echo "    Murmur128 vs NimHash: ", nimHashResult.lookupTime/murmur128Result.lookupTime, "x faster"
  echo "    Murmur32 vs NimHash: ", nimHashResult.lookupTime/murmur32Result.lookupTime, "x faster"
  echo "    Murmur128 vs Murmur32: ", murmur32Result.lookupTime/murmur128Result.lookupTime, "x faster"
  
  echo "  False Positive Rates:"
  let fpRateNimHash = nimHashResult.falsePositives.float / lookupData.len.float
  let fpRateMurmur128 = murmur128Result.falsePositives.float / lookupData.len.float
  let fpRateMurmur32 = murmur32Result.falsePositives.float / lookupData.len.float
  
  echo "    Murmur128 vs NimHash: ", fpRateNimHash/fpRateMurmur128, "x better"
  echo "    Murmur32 vs NimHash: ", fpRateNimHash/fpRateMurmur32, "x better"
  echo "    Murmur128 vs Murmur32: ", fpRateMurmur32/fpRateMurmur128, "x better"

when isMainModule:
  const errorRate = 0.01
  
  # Test each pattern
  for pattern in [dpRandom, dpSequential, dpFixed, dpLong, dpSpecial]:
    # Small dataset
    runBenchmark(10_000, errorRate, pattern, "Small " & $pattern)
    
    # Medium dataset
    runBenchmark(100_000, errorRate, pattern, "Medium " & $pattern)
    
    # Large dataset
    runBenchmark(1_000_000, errorRate, pattern, "Large " & $pattern)
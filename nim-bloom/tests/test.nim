import unittest
include bloom
from random import rand, randomize
import times

suite "murmur":
  # Test murmurhash 3 when enabled
  setup:
    var hashOutputs: MurmurHashes
    hashOutputs = [0, 0]
    rawMurmurHash("hello", 5, 0, hashOutputs)

  test "raw":
    check int(hashOutputs[0]) == -3758069500696749310 # Correct murmur outputs (cast to int64)
    check int(hashOutputs[1]) == 6565844092913065241

  test "wrapped":
    let hashOutputs2 = murmurHash("hello", 0)
    check hashOutputs2[0] == hashOutputs[0]
    check hashOutputs2[1] == hashOutputs[1]

  test "seed":
    let hashOutputs3 = murmurHash("hello", 10)
    check hashOutputs3[0] != hashOutputs[0]
    check hashOutputs3[1] != hashOutputs[1]

suite "hashing comparison":
  test "hash distribution":
    const testSize = 10000
    var standardCollisions = 0
    var extendedCollisions = 0
    
    var bfStandard = initializeBloomFilter(testSize, 0.01, useExtendedHash = false)
    var bfExtended = initializeBloomFilter(testSize, 0.01, useExtendedHash = true)
    
    # Generate test data
    var testData = newSeq[string](testSize)
    for i in 0..<testSize:
      testData[i] = $i & "salt" & $rand(1000000)
    
    # Test standard hash
    var startTime = cpuTime()
    for item in testData:
      bfStandard.insert(item)
    let standardTime = cpuTime() - startTime
    
    # Test extended hash
    startTime = cpuTime()
    for item in testData:
      bfExtended.insert(item)
    let extendedTime = cpuTime() - startTime
    
    echo "Standard hash time: ", standardTime
    echo "Extended hash time: ", extendedTime

test "hash implementation switch":
    # Create two filters with different hash implementations
    let standardBf = initializeBloomFilter(1000, 0.01, useExtendedHash = false)
    let murmurBf = initializeBloomFilter(1000, 0.01, useExtendedHash = true)
    
    # Insert same elements
    let testData = ["test1", "test2", "test3", "test4", "test5"]
    for item in testData:
      var stdBf = standardBf  # Create mutable copies
      var murBf = murmurBf
      stdBf.insert(item)
      murBf.insert(item)
      
      # Verify both can find their items
      check stdBf.lookup(item)
      check murBf.lookup(item)
    
    # Verify false positives work as expected for both
    let nonExistentItem = "definitely-not-in-filter"
    var falsePositiveStd = standardBf.lookup(nonExistentItem)
    var falsePositiveMur = murmurBf.lookup(nonExistentItem)
    
    # Both should maintain their error rates
    # Run multiple times to get a sample
    var fpCountStd = 0
    var fpCountMur = 0
    for i in 0..1000:
      let testItem = "test-" & $i
      if standardBf.lookup(testItem): fpCountStd += 1
      if murmurBf.lookup(testItem): fpCountMur += 1
    
    # Both should have similar false positive rates within reasonable bounds
    let fpRateStd = fpCountStd.float / 1000.0
    let fpRateMur = fpCountMur.float / 1000.0
    
    check abs(fpRateStd - fpRateMur) < 0.01  # Should be reasonably close
    check fpRateStd < standardBf.errorRate * 1.5  # Should not exceed target error rate by too much
    check fpRateMur < murmurBf.errorRate * 1.5

    echo "Standard hash false positive rate: ", fpRateStd
    echo "Murmur hash false positive rate: ", fpRateMur

suite "bloom":
  setup:
    let nElementsToTest = 100000
    var bf = initializeBloomFilter(capacity = nElementsToTest, errorRate = 0.001)
    randomize(2882) # Seed the RNG
    var
      sampleChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
      kTestElements = newSeq[string](nElementsToTest)

    for i in 0..<nElementsToTest:
      var newString = ""
      for j in 0..7:
        newString.add(sampleChars[rand(51)])
      kTestElements[i] = newString

    for i in 0..<nElementsToTest:
      bf.insert(kTestElements[i])

  test "init parameters":
    check(bf.capacity == nElementsToTest)
    check(bf.errorRate == 0.001)
    check(bf.kHashes == 10)
    check(bf.mBits == 15 * nElementsToTest)

  test "hash mode selection":
    let bf1 = initializeBloomFilter(100, 0.01)
    check(bf1.useExtendedHash == false)
    
    let bf2 = initializeBloomFilter(100, 0.01, useExtendedHash = true)
    check(bf2.useExtendedHash == true)

  test "basic operations":
    # Test empty lookup
    check(bf.lookup("nothing") == false)
    
    # Test insert and lookup
    bf.insert("teststring")
    check(bf.lookup("teststring") == true)
    
    # Test multiple inserts
    bf.insert("test1")
    bf.insert("test2")
    check(bf.lookup("test1") == true)
    check(bf.lookup("test2") == true)
    check(bf.lookup("test3") == false)

  test "large scale performance":
    let largeSize = 1_000_000
    var standardBf = initializeBloomFilter(largeSize, 0.001, useExtendedHash = false)
    var extendedBf = initializeBloomFilter(largeSize, 0.001, useExtendedHash = true)
    
    var largeData = newSeq[string](1000)
    for i in 0..<1000:
      largeData[i] = $i & "test" & $rand(1000000)
    
    # Insert and measure false positives for both
    var startTime = cpuTime()
    for item in largeData:
      standardBf.insert(item)
    let standardTime = cpuTime() - startTime
    
    startTime = cpuTime()
    for item in largeData:
      extendedBf.insert(item)
    let extendedTime = cpuTime() - startTime
    
    echo "Standard hash large insert time: ", standardTime
    echo "Extended hash large insert time: ", extendedTime

  test "error rate":
    var falsePositives = 0
    for i in 0..<nElementsToTest:
      var falsePositiveString = ""
      for j in 0..8:
        falsePositiveString.add(sampleChars[rand(51)])
      if bf.lookup(falsePositiveString):
        falsePositives += 1

    let actualErrorRate = falsePositives.float / nElementsToTest.float
    check actualErrorRate < bf.errorRate
    echo "Actual error rate: ", actualErrorRate
    echo "Target error rate: ", bf.errorRate

  test "lookup reliability":
    var lookupErrors = 0
    let startTime = cpuTime()
    for i in 0..<nElementsToTest:
      if not bf.lookup(kTestElements[i]):
        lookupErrors += 1
    let endTime = cpuTime()

    check lookupErrors == 0
    echo "Lookup time for ", nElementsToTest, " items: ", formatFloat(endTime - startTime, format = ffDecimal, precision = 4), " seconds"

  test "k/(m/n) specification":
    expect(BloomFilterError):
      discard getMOverNBitsForK(k = 2, targetError = 0.00001)

    check getMOverNBitsForK(k = 2, targetError = 0.1) == 6
    check getMOverNBitsForK(k = 7, targetError = 0.01) == 10
    check getMOverNBitsForK(k = 7, targetError = 0.001) == 16

  test "force params":
    var bf2 = initializeBloomFilter(10000, 0.001, k = 4, forceNBitsPerElem = 20)
    check(bf2.capacity == 10000)
    check(bf2.errorRate == 0.001)
    check(bf2.kHashes == 4)
    check(bf2.mBits == 200000)

  test "init error cases":
    expect(BloomFilterError):
      discard initializeBloomFilter(1000, 0.00001, k = 2)

    expect(BloomFilterError):
      discard initializeBloomFilter(1000, 0.00001, k = 13)

  test "string representation":
    let bf3 = initializeBloomFilter(1000, 0.01, k = 4)
    let str = $bf3
    check str.contains("1000")
    check str.contains("4 hash functions")
    check str.contains("1.0e-02")  # 0.01 in scientific notation
import unittest
import strutils
include bloom
from random import rand, randomize

suite "murmur":
  # Test murmurhash3 implementations
  setup:
    var hashOutputs: MurmurHashes
    hashOutputs = [0, 0]
    rawMurmurHash128("hello", 5, 0'u32, hashOutputs)

  test "murmur128 raw":
    check int(hashOutputs[0]) == -3758069500696749310
    check int(hashOutputs[1]) == 6565844092913065241

  test "murmur128 wrapped":
    let hashOutputs2 = murmurHash128("hello", 0'u32)
    check hashOutputs2[0] == hashOutputs[0]
    check hashOutputs2[1] == hashOutputs[1]

  test "murmur32":
    let hash1 = murmurHash32("hello", 0'u32)
    let hash2 = murmurHash32("hello", 0'u32)
    check hash1 == hash2  # Same input should give same output
    
    let hash3 = murmurHash32("hello", 10'u32)
    check hash1 != hash3  # Different seeds should give different outputs

suite "hash quality":
  test "hash type selection":
    let bfMurmur128 = initializeBloomFilter(100, 0.01, hashType = htMurmur128)
    let bfMurmur32 = initializeBloomFilter(100, 0.01, hashType = htMurmur32)
    let bfNimHash = initializeBloomFilter(100, 0.01, hashType = htNimHash)
    
    check bfMurmur128.hashType == htMurmur128
    check bfMurmur32.hashType == htMurmur32
    check bfNimHash.hashType == htNimHash

  test "quality across hash types":
    const testSize = 10_000
    let patterns = @[
      "shortstr",
      repeat("a", 1000),  # Very long string
      "special@#$%^&*()",  # Special characters
      "unicode→★∑≈",  # Unicode characters
      repeat("pattern", 10)  # Repeating pattern
    ]
    
    for hashType in [htMurmur128, htMurmur32, htNimHash]:
      var bf = initializeBloomFilter(testSize, 0.01, hashType = hashType)
      var inserted = newSeq[string](testSize)
      
      # Test pattern handling
      for pattern in patterns:
        bf.insert(pattern)
        check bf.lookup(pattern)
      
      # Test general insertion and lookup
      for i in 0..<testSize:
        inserted[i] = $i & "test" & $rand(1000)
        bf.insert(inserted[i])
      
      # Verify all insertions
      var lookupErrors = 0
      for item in inserted:
        if not bf.lookup(item):
          lookupErrors.inc
      check lookupErrors == 0
      
      # Check false positive rate
      var falsePositives = 0
      let fpTestSize = testSize div 2
      for i in 0..<fpTestSize:
        let testItem = "notpresent" & $i & $rand(1000)
        if bf.lookup(testItem):
          falsePositives.inc
      
      let fpRate = falsePositives.float / fpTestSize.float
      check fpRate < bf.errorRate * 1.5  # Allow some margin but should be close to target

suite "bloom filter":
  setup:
    let nElementsToTest = 10000
    var bf = initializeBloomFilter(capacity = nElementsToTest, errorRate = 0.001)
    randomize(2882) # Seed the RNG
    var
      sampleChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
      testElements = newSeq[string](nElementsToTest)

    for i in 0..<nElementsToTest:
      var newString = ""
      for j in 0..7:
        newString.add(sampleChars[rand(51)])
      testElements[i] = newString

    for item in testElements:
      bf.insert(item)

  test "initialization parameters":
    check bf.capacity == nElementsToTest
    check bf.errorRate == 0.001
    check bf.kHashes == 10
    check bf.mBits div bf.capacity == 15  # bits per element

  test "basic operations":
    check bf.lookup("nonexistent") == false  # Test empty lookup
    
    var bf2 = initializeBloomFilter(100, 0.01)
    bf2.insert("test string")
    check bf2.lookup("test string") == true
    check bf2.lookup("different string") == false

  test "error rate":
    var falsePositives = 0
    let testSize = nElementsToTest div 2
    for i in 0..<testSize:
      var testString = ""
      for j in 0..8:  # Different length than setup
        testString.add(sampleChars[rand(51)])
      if bf.lookup(testString):
        falsePositives.inc

    let actualErrorRate = falsePositives.float / testSize.float
    check actualErrorRate < bf.errorRate * 1.5  # Allow some margin
    
  test "perfect recall":
    var lookupErrors = 0
    for item in testElements:
      if not bf.lookup(item):
        lookupErrors.inc
    check lookupErrors == 0

  test "k/m bits specification":
    expect(BloomFilterError):
      discard getMOverNBitsForK(k = 2, targetError = 0.00001)

    check getMOverNBitsForK(k = 2, targetError = 0.1) == 6
    check getMOverNBitsForK(k = 7, targetError = 0.01) == 10
    check getMOverNBitsForK(k = 7, targetError = 0.001) == 16

    var bf2 = initializeBloomFilter(10000, 0.001, k = 4, forceNBitsPerElem = 20)
    check bf2.kHashes == 4
    check bf2.mBits == 200000

  test "string representation":
    let bf3 = initializeBloomFilter(1000, 0.01, k = 4)
    let str = $bf3
    check str.contains("1000")  # Capacity
    check str.contains("4 hash")  # Hash functions
    check str.contains("1.0e-02")  # Error rate in scientific notation
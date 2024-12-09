import unittest
include ../bloom_filter/bloom
from random import rand, randomize

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

suite "bloom filter special cases":
  test "different patterns of strings":
    const testSize = 10_000
    let patterns = @[
      "shortstr",
      repeat("a", 1000),  # Very long string
      "special@#$%^&*()",  # Special characters
      "unicode→★∑≈",  # Unicode characters
      repeat("pattern", 10)  # Repeating pattern
    ]
    
    var bf = initializeBloomFilter(testSize, 0.01)
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
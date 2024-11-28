from math import ceil, ln, pow, round
import hashes
import strutils
import private/probabilities

# Import MurmurHash3 code with both 128-bit and 32-bit implementations
{.compile: "murmur3.c".}

type
  HashType* = enum
    htMurmur128,  # Default: MurmurHash3_x64_128
    htMurmur32,   # MurmurHash3_x86_32
    htNimHash  # Nim's Hash (currently Farm Hash)

  BloomFilterError* = object of CatchableError
  
  MurmurHashes = array[0..1, int]
  
  BloomFilter* = object
    capacity*: int
    errorRate*: float
    kHashes*: int
    mBits*: int
    intArray: seq[int]
    hashType*: HashType

{.push overflowChecks: off.}  # Turn off overflow checks for hashing operations

proc rawMurmurHash128(key: cstring, len: int, seed: uint32,
                     outHashes: var MurmurHashes): void {.
  importc: "MurmurHash3_x64_128".}

proc rawMurmurHash32(key: cstring, len: int, seed: uint32,
                    outHashes: ptr uint32): void {.
  importc: "MurmurHash3_x86_32".}

proc murmurHash128(key: string, seed = 0'u32): MurmurHashes =
  var hashResult: MurmurHashes
  rawMurmurHash128(key, key.len, seed, hashResult)
  hashResult

proc murmurHash32(key: string, seed = 0'u32): uint32 =
  var result: uint32
  rawMurmurHash32(key, key.len, seed, addr result)
  result

proc hashN(item: string, n: int, maxValue: int): int =
  ## Get the nth hash using Nim's built-in hash function using
  ## the double hashing technique from Kirsch and Mitzenmacher, 2008:
  ## http://www.eecs.harvard.edu/~kirsch/pubs/bbbf/rsa.pdf
  let
    hashA = abs(hash(item)) mod maxValue  # Use abs to handle negative hashes
    hashB = abs(hash(item & " b")) mod maxValue # string concatenation
  abs((hashA + n * hashB)) mod maxValue
  #   # Use bit rotation for second hash instead of string concatenation if speed if preferred over FP-rate
  #   # Rotate left by 21 bits (lower the rotation, higher the speed but higher the FP-rate too) 
  #   hashB = abs(
  #     ((h shl 21) or (h shr (sizeof(int) * 8 - 21)))
  #   ) mod maxValue
  # abs((hashA + n.int64 * hashB)) mod maxValue

{.pop.}

proc getMOverNBitsForK(k: int, targetError: float,
    probabilityTable = kErrors): int =
  ## Returns the optimal number of m/n bits for a given k.
  if k notin 0..12:
    raise newException(BloomFilterError,
      "K must be <= 12 if forceNBitsPerElem is not also specified.")

  for mOverN in 2..probabilityTable[k].high:
    if probabilityTable[k][mOverN] < targetError:
      return mOverN

  raise newException(BloomFilterError,
    "Specified value of k and error rate not achievable using less than 4 bytes / element.")

proc initializeBloomFilter*(capacity: int, errorRate: float, k = 0,
                              forceNBitsPerElem = 0,
                              hashType = htMurmur128): BloomFilter =
  ## Initializes a Bloom filter with specified parameters.
  ##
  ## Parameters:
  ## - capacity: Expected number of elements to be inserted
  ## - errorRate: Desired false positive rate (e.g., 0.01 for 1%)
  ## - k: Optional number of hash functions. If 0, calculated optimally
  ## See http://pages.cs.wisc.edu/~cao/papers/summary-cache/node8.html for
  ## useful tables on k and m/n (n bits per element) combinations.
  ## - forceNBitsPerElem: Optional override for bits per element
  ## - hashType: Choose hash function:
  ##   * htMurmur128: MurmurHash3_x64_128 (default) - recommended
  ##   * htMurmur32: MurmurHash3_x86_32
  ##   * htNimHash: Nim's Hash
  var
    kHashes: int
    nBitsPerElem: int

  if k < 1: # Calculate optimal k and use that
    let bitsPerElem = ceil(-1.0 * (ln(errorRate) / (pow(ln(2.float), 2))))
    kHashes = round(ln(2.float) * bitsPerElem).int
    nBitsPerElem = round(bitsPerElem).int
  else: # Use specified k if possible
    if forceNBitsPerElem < 1: # Use lookup table
      nBitsPerElem = getMOverNBitsForK(k = k, targetError = errorRate)
    else:
      nBitsPerElem = forceNBitsPerElem
    kHashes = k

  let
    mBits = capacity * nBitsPerElem
    mInts = 1 + mBits div (sizeof(int) * 8)

  BloomFilter(
    capacity: capacity,
    errorRate: errorRate,
    kHashes: kHashes,
    mBits: mBits,
    intArray: newSeq[int](mInts),
    hashType: hashType
  )

proc `$`*(bf: BloomFilter): string =
  ## Prints the configuration of the Bloom filter.
  let hashType = case bf.hashType
    of htMurmur128: "MurmurHash3_x64_128"
    of htMurmur32: "MurmurHash3_x86_32"
    of htNimHash: "NimHashHash"
  
  "Bloom filter with $1 capacity, $2 error rate, $3 hash functions, and requiring $4 bits of memory. Using $5." %
    [$bf.capacity,
     formatFloat(bf.errorRate, format = ffScientific, precision = 1),
     $bf.kHashes,
     $(bf.mBits div bf.capacity),
     hashType]

{.push overflowChecks: off.}  # Turn off overflow checks for hash computations

proc computeHashes(bf: BloomFilter, item: string): seq[int] =
  var hashes = newSeq[int](bf.kHashes)
  
  case bf.hashType
  of htMurmur128:
    let murmurHashes = murmurHash128(item, 0'u32)
    for i in 0..<bf.kHashes:
      hashes[i] = abs((murmurHashes[0].int64 + i.int64 * murmurHashes[1].int64).int) mod bf.mBits
  of htMurmur32:
    let baseHash = murmurHash32(item, 0'u32)
    # let rotated = ((baseHash shl 13) or (baseHash shr (32 - 13)))
    let secondHash = murmurHash32(item & " b", 0'u32)
    for i in 0..<bf.kHashes:
      hashes[i] = abs((baseHash.int64 + i.int64 * secondHash.int64).int) mod bf.mBits
  
  of htNimHash:
    for i in 0..<bf.kHashes:
      hashes[i] = hashN(item, i, bf.mBits)
  
  hashes

{.pop.}  # Restore overflow checks

proc insert*(bf: var BloomFilter, item: string) =
  ## Insert an item (string) into the Bloom filter.
  let hashSet = bf.computeHashes(item)
  for h in hashSet:
    let
      intAddress = h div (sizeof(int) * 8)
      bitOffset = h mod (sizeof(int) * 8)
    bf.intArray[intAddress] = bf.intArray[intAddress] or (1 shl bitOffset)

proc lookup*(bf: BloomFilter, item: string): bool =
  ## Lookup an item (string) in the Bloom filter.
  ## If the item is present, ``lookup`` is guaranteed to return ``true``.
  ## If the item is not present, ``lookup`` will return ``false``
  ## with a probability 1 - ``bf.errorRate``.
  let hashSet = bf.computeHashes(item)
  for h in hashSet:
    let
      intAddress = h div (sizeof(int) * 8)
      bitOffset = h mod (sizeof(int) * 8)
      currentInt = bf.intArray[intAddress]
    if currentInt != (currentInt or (1 shl bitOffset)):
      return false
  true
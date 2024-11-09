from math import ceil, ln, pow, round
import hashes
import strutils
import private/probabilities

# Import MurmurHash3 code for large-scale use cases
{.compile: "murmur3.c".}

type
  BloomFilterError* = object of CatchableError
  MurmurHashes = array[0..1, int]
  BloomFilter* = object
    capacity*: int
    errorRate*: float
    kHashes*: int
    mBits*: int
    intArray: seq[int]
    useExtendedHash*: bool  # Use 128-bit MurmurHash3 for very large filters

{.push overflowChecks: off.}  # Turn off overflow checks for hashing operations

proc rawMurmurHash(key: cstring, len: int, seed: uint32,
                     outHashes: var MurmurHashes): void {.
  importc: "MurmurHash3_x64_128".}

proc murmurHash(key: string, seed = 0'u32): MurmurHashes =
  rawMurmurHash(key, key.len, seed, result)

proc hashN(item: string, n: int, maxValue: int): int =
  ## Get the nth hash using Nim's built-in hash function using
  ## the double hashing technique from Kirsch and Mitzenmacher, 2008:
  ## http://www.eecs.harvard.edu/~kirsch/pubs/bbbf/rsa.pdf
  let
    hashA = abs(hash(item)) mod maxValue  # Use abs to handle negative hashes
    hashB = abs(hash(item & " b")) mod maxValue
  abs((hashA + n * hashB)) mod maxValue

{.pop.}  # Restore overflow checks

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
    "Specified value of k and error rate for which is not achievable using less than 4 bytes / element.")

proc initializeBloomFilter*(capacity: int, errorRate: float, k = 0,
                              forceNBitsPerElem = 0,
                              useExtendedHash = false): BloomFilter =
  ## Initializes a Bloom filter, using a specified ``capacity``,
  ## ``errorRate``, and – optionally – specific number of k hash functions.
  ## If ``kHashes`` is < 1 (default argument is 0), ``kHashes`` will be
  ## optimally calculated. If capacity > 1M elements, consider setting
  ## useExtendedHash = true to use 128-bit MurmurHash3 for better 
  ## collision resistance.
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
    useExtendedHash: useExtendedHash
  )

proc `$`*(bf: BloomFilter): string =
  ## Prints the capacity, set error rate, number of k hash functions,
  ## and total bits of memory allocated by the Bloom filter.
  "Bloom filter with $1 capacity, $2 error rate, $3 hash functions, and requiring $4 bits of memory." %
    [$bf.capacity,
     formatFloat(bf.errorRate, format = ffScientific, precision = 1),
     $bf.kHashes,
     $(bf.mBits div bf.capacity)]

{.push overflowChecks: off.}  # Turn off overflow checks for hash computations

proc computeHashes(bf: BloomFilter, item: string): seq[int] =
  var hashes = newSeq[int](bf.kHashes)
  if bf.useExtendedHash:
    let murmurHashes = murmurHash(item, 0'u32)
    for i in 0..<bf.kHashes:
      hashes[i] = abs((murmurHashes[0] + i.int64 * murmurHashes[1].int64).int) mod bf.mBits
  else:
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
  ## Lookup an item (string) into the Bloom filter.
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
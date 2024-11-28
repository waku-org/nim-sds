# nim-bloom

A high-performance Bloom filter implementation in Nim offering standard and custom hash function options with different performance characteristics and false positive rates.

## Features

- Fast string element insertion and lookup
- Configurable error rates
- Choice between standard Nim hash and custom MurmurHash3 (128-bit or 32-bit)
- Optimized for supporting different use cases of speed and accuracy
- Comprehensive test suite and benchmarks

## Usage

Basic usage (defaults to MurmurHash3_128):
```nim
import bloom2

# Initialize with default hash (MurmurHash3_128)
var bf = initializeBloomFilter(capacity = 10000, errorRate = 0.01)

# Or explicitly specify hash type
var bf32 = initializeBloomFilter(
  capacity = 10000, 
  errorRate = 0.01,
  hashType = htMurmur32  # Use 32-bit implementation
)

# Basic operations
bf.insert("test")
assert bf.lookup("test")
```

## Hash Function Selection

1. Use MurmurHash3_128 (default) when:
    - You need the best balance of performance and accuracy
    - Memory isn't severely constrained
    - Working with large datasets
    - False positive rates are important

2. Use MurmurHash3_32 when:
    - Running on 32-bit systems
    - Memory is constrained
    - Working with smaller datasets
    - String concatenation overhead for second hash, causing higher insertion and lookup times, is acceptable.

3. Use NimHash when:
    - Consistency with Nim's default hashing is important
    - Working with smaller datasets where performance is less critical
    - Future availability of better hash functions or performant implementations

Nim's Hash Implementation:
  - Default (no flags): Uses FarmHash implementation
  - With `-d:nimStringHash2`: Uses Nim's MurmurHash3_32 implementation
  - Our implementation allows explicit choice regardless of compilation flags and our MurmurHash3_32 performs better because of directly using a native C Implementation

## Performance Characteristics
### For 1M items - Random Strings
```
Insertion Speed:
MurmurHash3_128: ~6.8M ops/sec
MurmurHash3_32:  ~5.9M ops/sec
FarmHash:        ~2.1M ops/sec

False Positive Rates:
MurmurHash3_128: ~0.84%
MurmurHash3_32:  ~0.83%
FarmHash:        ~0.82%
```

These measurements show MurmurHash3_128's balanced performance profile, offering best speed and competitive false positive rates.

Performance will vary based on:
- Choice of hash function
- Hardware specifications
- Data size and memory access patterns (inside vs outside cache)
- Compiler optimizations

For detailed benchmarks across different data patterns and sizes, see [benches](benches/).

## Implementation Details

### Double Hashing Technique
This implmentation uses the Kirsch-Mitzenmacher method to generate k hash values from two initial hashes. The implementation varies by hash type:

1. MurmurHash3_128:
```nim
h(i) = abs((hash1 + i * hash2) mod m)
```
- Uses both 64-bit hashes from 128-bit output
- Natural double-hash implementation

2. MurmurHash3_32:
```nim
let baseHash = murmurHash32(item, 0'u32)
let secondHash = murmurHash32(item & " b", 0'u32)
```
- Uses string concatention by default for the second hash
- Bit Rotation for second hash provides sufficient randomness in some use cases while being much faster than string concatenation (but results in higher FP rate)
- Choose between bit rotation or string concatenation as per your use-case.

3. Nim's Default Hash:
```nim
  let
    hashA = abs(hash(item)) mod maxValue
    hashB = abs(hash(item & " b")) mod maxValue
  h(i) = abs((hashA + n * hashB)) mod maxValue
```
- Farm Hash or Nim's Murmur Hash based (if compliation flag is passed)
- Uses string concatention by default.
- Lower FP rate than bit rotation but comes at the cost of higher insertion and lookup times.

*Tip:* Bit rotation values can be configurable as well. Use prime numbers for better mixing: 7, 11, 13, 17 for 32-bit; 21, 23, 27, 33 for 64-bit. Smaller rotations provides lesser mixing but as faster than higher rotations.

## Testing

Run the test suite:
```bash
nimble test
```
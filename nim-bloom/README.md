# nim-bloom

A high-performance Bloom filter implementation in Nim. Supports both Nim's built-in MurmurHash2 (default) and an optional 128-bit MurmurHash3 implementation for large-scale use cases.

## Features

- Fast string element insertion and lookup
- Configurable error rates
- Choice between standard Nim hash (MurmurHash2) and extended 128-bit MurmurHash3
- Optimized for both small and large-scale use cases
- Comprehensive test suite

## Performance

Historical benchmark using MurmurHash3 implementation on a 10-year-old Macbook Pro Retina:
- ~2.5M insertions/sec (~4.0 seconds for 10M insertions)
- ~2.9M lookups/sec (~3.5 seconds for 10M lookups)
- Test configuration: 0.001 error rate, Bloom filter size ~20-25MB
- Compiled with `-d:release` flag

These numbers reflect performance outside of CPU cache, as the filter size was intentionally larger than L3 cache. Performance can be several million operations/sec higher with smaller filters that fit in cache.

Current performance will vary based on:
- Choice of hash function (standard Nim hash vs extended MurmurHash3)
- Hardware specifications
- Data size and memory access patterns
- Compiler optimizations

The default configuration (using Nim's built-in hash) is optimized for typical use cases, while the extended hash option (MurmurHash3) provides better collision resistance for large-scale applications at a slight performance cost.

## Quickstart

Basic usage:
```nim
import bloom

# Initialize with default hash (suitable for most uses)
var bf = initializeBloomFilter(capacity = 10000, errorRate = 0.001)
echo bf  # Print Bloom filter characteristics
echo bf.lookup("test")  # false
bf.insert("test")
assert bf.lookup("test")  # true

# For large-scale usage (>1M elements), consider using extended hash
var largeBf = initializeBloomFilter(
  capacity = 2_000_000,
  errorRate = 0.001,
  useExtendedHash = true
)
```

## Advanced Configuration

The Bloom filter can be configured in several ways:

1. Default initialization (automatically calculates optimal parameters):
```nim
var bf = initializeBloomFilter(capacity = 10000, errorRate = 0.001)
```

2. Specify custom number of hash functions:
```nim
var bf = initializeBloomFilter(
  capacity = 10000,
  errorRate = 0.001,
  k = 5  # Use 5 hash functions instead of calculated optimal
)
```

3. Fully manual configuration:
```nim
var bf = initializeBloomFilter(
  capacity = 10000,
  errorRate = 0.001,
  k = 5,
  forceNBitsPerElem = 12,
  useExtendedHash = false  # Use standard hash (default)
)
```

Note: When specifying `k`, it must be ≤ 12 unless `forceNBitsPerElem` is also specified. The implementation will raise a `BloomFilterError` if parameters would result in suboptimal performance.

## Hash Function Selection

- Default: Uses Nim's built-in hash (MurmurHash2), suitable for most use cases
- Extended: Uses 128-bit MurmurHash3, better for large sets (>1M elements) where collision resistance is critical

Choose extended hash by setting `useExtendedHash = true` during initialization.

## Testing

Run the test suite:
```bash
nimble test
```
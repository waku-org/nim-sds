# Changelog

All notable changes to **nim-sds** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-06-19

### Added
- SDS-Repair (SDS-R) support, implementing the repair extension from the SDS spec ([#60](https://github.com/logos-messaging/nim-sds/pull/60)).
- Persistence interface for SDS state, refactored into a snapshot-based, fully async API with atomic per-operation semantics ([#66](https://github.com/logos-messaging/nim-sds/pull/66), [#69](https://github.com/logos-messaging/nim-sds/pull/69), [#72](https://github.com/logos-messaging/nim-sds/pull/72), [#73](https://github.com/logos-messaging/nim-sds/pull/73)).
- Nimble-based build system for the core library and FFI targets ([#52](https://github.com/logos-messaging/nim-sds/pull/52)).
- `CLAUDE.md` contributor/architecture guide ([#58](https://github.com/logos-messaging/nim-sds/pull/58)).

### Changed
- **Breaking (C ABI):** adopted nim-ffi v0.1.5 and migrated the C FFI to its macro-generated API. All exported symbols are renamed from PascalCase `Sds*` to snake_case `sds_*` (e.g. `SdsNewReliabilityManager` → `sds_create`, `SdsCleanupReliabilityManager` → `sds_destroy`). Consumers such as sds-go-bindings must update to the new names ([#81](https://github.com/logos-messaging/nim-sds/pull/81)).
- Replaced the nim-libp2p protobuf dependency with nim-protobuf-serialization for message encoding/decoding ([#77](https://github.com/logos-messaging/nim-sds/pull/77)).
- **Breaking (API):** `participantId` is now required when creating a `ReliabilityManager` ([#67](https://github.com/logos-messaging/nim-sds/pull/67)).
- General refactor to align the codebase with the logos-delivery style ([#62](https://github.com/logos-messaging/nim-sds/pull/62)).

### Fixed
- Restored `-d:noSignalHandler` for the libsds build so the embedded library does not install signal handlers.
- Forced `epoll` usage on Android.

## [0.3.0]

Earlier releases were not tracked in this changelog. See the
[release tags](https://github.com/logos-messaging/nim-sds/tags) for history
prior to 0.4.0.

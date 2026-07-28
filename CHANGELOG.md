# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.2] - 2026-07-28

### Fixed

- A raising `ActiveSupport::Notifications` subscriber can no longer strand a worker at the raised polling interval mid-registration, or run between a notification and the worker wake-ups it triggers.

### Changed

- Internal: the registry is now the single owner of per-worker state (queue snapshot and replaced polling interval); the `notify` event's duration no longer includes the dispatch itself (payload unchanged).

## [0.5.1] - 2026-07-28

### Fixed

- `SOLID_QUEUE_LISTEN_NOTIFY_ENABLED=false` now disables the gem even when the application sets `enabled` explicitly. It previously only seeded the default, so an app configuring `enabled` at all silently lost the environment kill switch.

## [0.5.0] - 2026-07-27

### First official release



[Unreleased]: https://github.com/cmer/solid_queue-listen_notify/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/cmer/solid_queue-listen_notify/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/cmer/solid_queue-listen_notify/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/cmer/solid_queue-listen_notify/compare/v0.1.0...v0.5.0
[0.1.0]: https://github.com/cmer/solid_queue-listen_notify/releases/tag/v0.1.0

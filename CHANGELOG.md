# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Agent-executable install/uninstall prompts in `prompts/`, linked from the README.

### Pre-release hardening

Everything below landed before 0.1.0 shipped, from an adversarial review of the
first cut. Listed separately because each one is a bug somebody would otherwise
have hit, not a design change.

- **Queue matching no longer misses queues the selector claims.**
  `SolidQueue::QueueSelector` turns a `prefix*` entry into `LIKE 'prefix%'`,
  where a `_` in the entry matches any single character — so a worker on
  `user_*` really does claim the queue `users`, and matching on the literal
  `user_` never woke it. The wake prefix now stops at the first `LIKE`
  metacharacter rather than at the first `*`, which keeps the "over-match,
  never under-match" guarantee intact. A differential test checks the matcher
  against an independent oracle over a few thousand entry/queue-name pairs.
- **The channel-drift check can no longer be satisfied by a substring.** It
  asked whether the channel name appeared anywhere in the trigger function's
  source; the function is called `solid_queue_listen_notify_ready`, so channels
  named `ready`, `notify`, `listen` or `queue` matched the function's own name
  and passed for a trigger notifying something else entirely. It now looks for
  the exact `pg_notify('<channel>', NEW.queue_name)` call.
- **The preflight self-test now spans two connections.** It `LISTEN`s on the
  listener's connection and sends the `NOTIFY` from a pooled connection to the
  queue database — the real delivery path. Doing both halves on one connection
  proved only that Postgres delivers a session its own notifications, and was
  blind to a `listen_database` pointing at a reachable but wrong database. The
  failure banner names that case.
- **`installed?` is schema-aware.** It matched `pg_class` on the bare relation
  name, so a trigger on another schema's copy of `solid_queue_ready_executions`
  counted as installed. It now resolves the table with `to_regclass`, through
  the same `search_path` the inserts use.
- **Channel length is validated (1–63 bytes).** A longer channel truncates
  silently in `LISTEN`/`NOTIFY` but makes the trigger's `pg_notify()` raise
  `channel name too long` on every enqueue. The generator now refuses to write
  the migration, `TriggerInstaller#install!` raises, and the preflight fails
  with a new `:invalid_channel` reason and a banner, before opening a
  connection.
- **`listen_database` survives a fork.** Active Record's own post-fork hook
  discards the private pool behind `listen_database`, leaving a memoized
  reference that raises on first checkout — the gem was silently inactive in
  every forked child. The fork hook now drops that memo, and the memo is keyed
  by pid as a backstop.
- **No lock is inherited across a fork any more.** `fork()` copies only the
  calling thread, so a mutex another thread held is inherited with nobody left
  to release it. CRuby abandons those itself, so this was not a live hang — but
  the widest window is the preflight's, held across connecting and a two-second
  self-test, and a child that inherited it would hang the first worker to
  register, silently, inside a lifecycle hook. The fork hook now replaces the
  preflight lock, the registry's creation lock and the connection provider's
  mutex while the child is still single-threaded, rather than depending on an
  interpreter implementation detail.
- **A raising instrumentation subscriber no longer kills the listener.** Your
  `ActiveSupport::Notifications` subscribers run on the listener thread; a bug
  in one used to end notifications for the lifetime of the process. Subscriber
  exceptions are now caught and reported once per exception class, while
  exceptions from the gem's own work inside an instrumented block still
  propagate, so a connection error in a keepalive still triggers a reconnect.
- **A listener that dies for good restores the polling intervals it raised.**
  The registry detaches the dead listener, every raised interval goes back, each
  worker is woken so it re-reads it, and one `ERROR` line says what happened.
  A worker left polling every 10 seconds with nothing to wake it was the one
  failure this gem must never cause.
- **Worker shutdown no longer joins the listener thread.** Deregistering used to
  spend up to three seconds of Solid Queue's five-second shutdown budget waiting
  for a thread that unwinds on its own; it now latches and returns. Resets still
  join, so tests stay deterministic.
- **The failure counter resets on a successful connect**, not only on a
  notification or keepalive, so a connection flapping faster than
  `keepalive_interval` cannot climb past the reporting threshold once and then
  report every failure forever.
- The fork-safety integration test now forces a GC in the child, which is what
  makes it catch the passive failure mode: an inherited connection that is never
  `discard!`ed is collected, and libpq's finalizer sends a termination packet
  down the parent's session.

## [0.1.0] - 2026-07-27

First release.

### Added

- Postgres `AFTER INSERT` trigger on `solid_queue_ready_executions` that calls
  `pg_notify(channel, NEW.queue_name)`, covering every path that makes a job
  ready. Installed by `bin/rails generate solid_queue:listen_notify:install`,
  which writes a migration with literal, self-contained SQL so it keeps working
  after the gem is removed. `--database` (default `queue`) picks the migrations
  path.
- One listener thread per worker process, holding one dedicated Postgres
  connection removed from its pool and pinned to the writing role, that
  multiplexes notifications to every Solid Queue worker in the process — one
  connection whether the process runs one worker or, in `async` mode, several.
- Queue routing that replicates `SolidQueue::QueueSelector`'s string semantics
  (`*`, exact names, `prefix*`) in pure Ruby, so dispatching a notification
  costs no database queries.
- Boot-time preflight that refuses to activate unless it can prove
  notifications arrive: adapter check, trigger presence, channel drift check
  against the installed function body, and a `LISTEN`/`NOTIFY` self-test on the
  listener's own connection. Every failure is a multi-line banner in the log
  explaining the cause and the fix, and leaves workers polling exactly as they
  would without the gem installed.
- PgBouncer (transaction-mode pooling) detection via that self-test, enriched
  with a `pg_backend_pid()` heuristic, plus a `listen_database` option that
  gives the listener a private connection straight to Postgres.
- Automatic polling-interval override: once notifications are proven, workers
  polling more often than `fallback_polling_interval` (default 10 seconds) are
  raised to it. Never lowers an interval, never applies when the gem is not
  operational, and is rolled back if registration then fails.
- Reconnection with backoff, keepalives, and error reporting to
  `SolidQueue.on_thread_error` only after
  `connection_errors_reporting_threshold` consecutive failures.
- Fork guard for clustered Puma with `solid_queue_mode :async`: a
  `ForkTracker.after_fork` hook and pid checks at every registry entry point
  `discard!` the inherited connection (never `disconnect!`, which would kill the
  parent's session), reset the registry, and log at `WARN`.
- `wake_saturated_workers`, `auto_install_trigger`, `wait_timeout`,
  `keepalive_interval`, `reconnect_wait`, `application_name`,
  `connection_provider` and `channel` configuration, settable either through
  `config.solid_queue_listen_notify` or directly on
  `SolidQueue::ListenNotify`, plus a `SOLID_QUEUE_LISTEN_NOTIFY_ENABLED=false`
  kill switch.
- `ActiveSupport::Notifications` events (`preflight`, `start_listener`,
  `notify`, `keepalive`, `reconnect`, `install_trigger`, `fork_detected`,
  `shutdown`, `override_polling_interval`) and a log subscriber formatted like
  Solid Queue's own.

[Unreleased]: https://github.com/cmer/solid_queue-listen_notify/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/cmer/solid_queue-listen_notify/releases/tag/v0.1.0

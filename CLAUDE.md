# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this gem is

Optional Postgres LISTEN/NOTIFY wake-ups for Solid Queue: a database trigger on `solid_queue_ready_executions` fires `pg_notify(channel, queue_name)` on commit, and one listener thread per worker process wakes matching workers via Solid Queue's public `wake_up`. Polling remains the correctness backstop — notifications are purely a latency optimization, and **every failure mode must degrade loudly to stock Solid Queue behavior** (banner in the log, gem inactive, polling intervals untouched or restored).

Two hard constraints shape everything:

1. **Zero monkey patches.** Solid Queue is integrated only through documented lifecycle hooks (`on_worker_start`/`on_worker_stop`, wired in the Railtie inside `ActiveSupport.on_load(:solid_queue)`) and public methods (`wake_up`, `queues`, `polling_interval=`, `pool.idle?`, `alive?`). Some of these are public-by-visibility rather than documented contract — that is why CI has an allowed-to-fail cell against `solid_queue@main`.
2. **The gem must load and pass its unit tier with no `pg`, `rails`, or `solid_queue` loaded.** Every reference to those is lazy (inside method bodies, `defined?`-guarded, error classes resolved by name at rescue time in `Listener.connection_errors`). Related trap: inside `module SolidQueue`, bare `Process` resolves to the `SolidQueue::Process` AR model once solid_queue is loaded — always write `::Process`.

## Commands

Postgres is required for integration tests (LISTEN can't be faked). Either `docker compose up -d` (publishes 127.0.0.1:55432, user `postgres` — what CI uses) or point env vars at a local server:

```bash
POSTGRES_PORT=5432 POSTGRES_USER=$(whoami) bundle exec rake test   # full suite (unit + integration)
bundle exec rake test:unit                                         # no DB, no Rails — runs anywhere
POSTGRES_PORT=5432 POSTGRES_USER=$(whoami) bundle exec rake test:integration
bundle exec rubocop                                                # rubocop-rails-omakase

# Single file / single test:
bundle exec ruby -Itest test/unit/queue_matcher_test.rb
POSTGRES_PORT=5432 POSTGRES_USER=$(whoami) bundle exec ruby -Itest test/integration/wake_latency_test.rb -n /latency/

# Other Rails versions (Appraisals: rails_7_1, rails_8_1, solid_queue_main):
BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle exec rake test
bundle exec appraisal generate                                     # after editing Appraisals
```

`test/integration_helper.rb` creates and schema-loads both dummy databases itself on every run — there is no separate db:setup step, and a stale test DB can never explain a failure.

## Architecture

`lib/solid_queue/listen_notify.rb` is the facade: config (`mattr_accessor`, mirroring solid_queue's style; copied from `config.solid_queue_listen_notify` by the Railtie), `register`/`deregister` (called from the lifecycle hooks; fully rescued — this gem must never make a worker look broken), the per-pid memoized `operational?`, and `after_fork`.

Flow at worker boot: `register(worker)` → `operational?` runs **Preflight** once per process → if operational, raise the worker's `polling_interval` to `fallback_polling_interval` (only ever raise, record the original) → `Registry.instance.register(worker)` starts the **Listener** on first registration.

- **`Preflight`** (`preflight.rb`) — decides operational-or-not; never raises; each failure prints an actionable WARN/ERROR banner (loud failure is a product requirement, not a nicety). Checks in order: enabled → channel 1–63 bytes → adapter is PG → trigger installed (auto-installed by default when missing) → trigger function body contains the exact `pg_notify('<channel>', ...)` call → **cross-connection self-test**: LISTEN on the listener's connection path, NOTIFY from a pooled queue-DB connection. Cross-connection is what detects both PgBouncer transaction pooling and a `listen_database` pointing at the wrong database.
- **`Registry`** (`registry.rb`) — per-process singleton multiplexing one listener to N workers (async mode runs N workers as threads in one process). Locking discipline is documented in its header comment and must be preserved: the mutex is never held across `wake_up`, `listener.stop`, or anything blocking; listeners are detached under the lock and stopped outside it. Cleanup is crash-tolerant, never hook-dependent (`on_worker_stop` is skipped on SIGQUIT `exit!`): dead workers are reaped on register and on the keepalive tick.
- **`Listener`** (`listener.rb`) — one thread, one dedicated connection produced by **`ConnectionProvider`** (GoodJob-style `pool.checkout` + `pool.remove`, pinned to the writing role; `listen_database` gets a private handler). Loop: `wait_for_notify(1s)` slices → `registry.dispatch(payload)`; `SELECT 1` keepalive every 10s; reconnect with backoff on connection errors, reporting to `SolidQueue.on_thread_error` only past a consecutive-failure threshold. On a *fatal* (non-connection) error it calls `registry.listener_crashed` so every polling interval this gem raised is restored and the workers woken — a worker left at 10s with nothing to wake it is the one failure this gem must never cause.
- **`QueueMatcher`** (`queue_matcher.rb`) — pure-Ruby replica of `QueueSelector` semantics, DB-free, with one deliberate asymmetry: it may over-wake but must never under-wake. Wildcard entries anchor on the literal text before the first `*` **or LIKE metacharacter** (`_`, `%`, `\`) because `QueueSelector` compiles `user_*` to `LIKE 'user_%'` where `_` matches any character. A differential test against a Ruby LIKE oracle asserts zero misses over thousands of pairs.
- **`TriggerInstaller`** (`trigger_installer.rb`) — DDL, injected connection, no pool management. `installed?` resolves the table with `to_regclass` (search_path-aware). The generator's migration template contains literal SQL that must stay in sync with the installer — a unit test renders the template and compares.

### Fork safety (Puma clustered + async mode)

The listener's connection is invisible to ActiveRecord's post-fork `discard_pools!` because it was removed from its pool. `ListenNotify.after_fork` (ForkTracker) plus pid checks at registry entry points handle it: in the child, the inherited adapter is **`discard!`ed, never `disconnect!`ed** — disconnect sends a termination packet down the socket shared with the parent and kills the parent's session. The hook also replaces every mutex in the gem and makes the provider forget memoized `listen_database` pools (AR discarded them behind our back). The fork integration test forces GC in the child specifically to catch the passive failure mode (ruby-pg's finalizer calls `PQfinish` unconditionally); it was validated by mutation — sabotaging `discard!` makes it fail.

### Testing rules

- Integration tests extend `IntegrationTestCase` and are **non-transactional by necessity** — Postgres delivers NOTIFY on commit, so a transactional test never sees one. Cleanup is `destroy_records` in setup and teardown, unique queue names per test, `wait_for`-style polling helpers (copied from solid_queue's harness) instead of fixed sleeps.
- Instrumentation events use the `*.solid_queue_listen_notify` namespace. The listener-start event is `start_listener`, not `start` — `ActiveSupport::Subscriber` silently refuses to subscribe methods named `start`/`finish`.
- `test/dummy` is a minimal PG-only Rails app (primary + `queue` databases, `connects_to` on the queue DB) modeled on solid_queue's own dummy.

## Reference

`docs/REFERENCE.md` documents every config option, log line, instrumentation payload, and failure mode — keep it (and the README's small config table) in sync with code when changing defaults or behavior. A local read-only checkout of solid_queue v1.5.0 typically lives at `../solid_queue` for cross-referencing upstream internals.

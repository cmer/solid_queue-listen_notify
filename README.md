# solid_queue-listen_notify

Optional Postgres LISTEN/NOTIFY wake-ups for [Solid Queue](https://github.com/rails/solid_queue).

Solid Queue workers find work by polling `solid_queue_ready_executions`, by default every 0.1 seconds. That is a query per worker per tenth of a second, forever, whether or not there is anything to do. This gem installs a database trigger that sends a `pg_notify` the moment a job becomes ready, and a listener that wakes the workers in the process when one arrives. With that in place you can raise `polling_interval` to 10–60 seconds and cut the idle query load by two or three orders of magnitude without paying for it in latency.

Polling stays. It is the correctness backstop, and notifications are purely a latency optimization: if the trigger is missing, the adapter isn't Postgres, the database is down at boot, a pooler eats the `LISTEN`, or the listener connection drops, the gem marks itself inactive, says so loudly in the log, leaves the polling interval exactly as your application configured it, and you are running stock Solid Queue.

**Measured on a local machine** (Postgres 15, macOS, worker at `polling_interval: 60`): enqueue to pickup takes **~50–60 ms**, versus up to 60 seconds if polling were the only path. Your numbers will differ; the point is the order of magnitude.

## Table of Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [What you'll see in the logs](#what-youll-see-in-the-logs)
- [Failure modes](#failure-modes)
- [Important caveats](#important-caveats)
- [Designed to be deletable](#designed-to-be-deletable)
- [Development and testing](#development-and-testing)
- [Contributing](#contributing)
- [License](#license)

## How it works

An `AFTER INSERT` trigger on `solid_queue_ready_executions` calls `pg_notify(channel, NEW.queue_name)`. Every path that makes a job ready — the bulk `insert_all` the dispatcher and `enqueue_all` use, the `create_or_find_by!` behind an immediate enqueue, a blocked execution being promoted when its concurrency lock frees up — ends in an insert on that table, so all of them are covered without the gem touching a line of Solid Queue's code.

Postgres delivers notifications **on commit**, and it collapses duplicate `(channel, payload)` pairs within a transaction, so a bulk enqueue of 500 jobs on one queue sends one notification, and a job enqueued inside a transaction that rolls back sends none.

On the receiving side there is **one listener thread with one dedicated connection per worker process**, not per worker. In `async` mode a single process runs N workers in N threads; a per-worker connection would be N connections doing the same thing. Instead a registry keeps track of the workers in the process and fans each notification out to the ones whose queue list matches the payload, using a pure-Ruby copy of Solid Queue's `QueueSelector` string semantics (`*`, exact names, `prefix*`) so that routing costs no database queries. Waking a worker calls its public `wake_up`, which writes a byte to the worker's self-pipe — the same mechanism Solid Queue's own thread pool uses.

Matching is deliberately asymmetric: waking a worker that turns out to have nothing to do costs one wasted poll, while failing to wake one costs latency, so wherever exact parity with `QueueSelector` would need a query the matcher over-matches instead. That is also why a glob is matched on the literal text before its first `*` **or** its first SQL `LIKE` metacharacter: `QueueSelector` turns `user_*` into `LIKE 'user_%'`, where the `_` matches any single character, so a worker on `user_*` really does claim the queue `users` — and the matcher wakes it, by anchoring on `user`. The differential test in `test/unit/queue_matcher_test.rb` checks this against an independent oracle over a few thousand entry/queue-name pairs, and asserts zero misses.

```
  enqueue ──► solid_queue_ready_executions ──► trigger ──► pg_notify("solid_queue_ready", queue_name)
                                                                          │  (on COMMIT)
                                                                          ▼
                                        ┌───────────── worker process ─────────────┐
                                        │  listener thread (1 dedicated connection) │
                                        │                  │ registry.dispatch      │
                                        │      ┌───────────┼───────────┐            │
                                        │   worker A    worker B    worker C        │
                                        │   wake_up     wake_up     (queues         │
                                        │                            don't match)   │
                                        └───────────────────────────────────────────┘
```

The listener's connection is checked out of the pool and then **removed** from it, so it is never handed to application code while it sits in `wait_for_notify`. It is pinned to the writing role: a `LISTEN` on a replica hears nothing.

## Requirements

- **PostgreSQL 12+.** The trigger uses `EXECUTE FUNCTION`, which needs Postgres 11; 12 is the documented floor because that is the oldest release still worth supporting. On Postgres 14 and up the trigger is installed with `CREATE OR REPLACE TRIGGER`; below that, with a `DROP` followed by a `CREATE`.
- **Solid Queue >= 1.5**
- **Rails / Active Record 7.1+**
- **Ruby 3.2+**

Only the queue database has to be Postgres. Your primary database can be anything.

## Installation

```bash
bundle add solid_queue-listen_notify
bin/rails generate solid_queue:listen_notify:install --database queue
bin/rails db:migrate
```

Then run `bin/jobs` (or the Puma plugin) exactly as before. There is nothing to start and nothing to configure: the gem wires itself into Solid Queue's `on_worker_start` / `on_worker_stop` lifecycle hooks, and when the first worker in a process starts it checks that it can actually deliver notifications before it changes anything.

The generator's `--database` option defaults to **`queue`**, which is the database name Solid Queue's own installer sets up, and it decides which `migrations_paths` the migration is written to. Change it if Solid Queue lives somewhere else in your `config/database.yml` — most commonly when it shares the primary database:

```bash
bin/rails generate solid_queue:listen_notify:install --database primary
```

The generated migration contains literal SQL with the channel name baked in. It doesn't reference the gem at all, so it keeps replaying (and reverting) after the gem is removed. If you change `channel` from its default, configure it **before** running the generator.

## Configuration

Set options either through the Railtie, in `config/application.rb` or an environment file:

```ruby
config.solid_queue_listen_notify.fallback_polling_interval = 30.seconds
config.solid_queue_listen_notify.auto_install_trigger = true
```

...or directly on the module, from an initializer:

```ruby
# config/initializers/solid_queue_listen_notify.rb
SolidQueue::ListenNotify.fallback_polling_interval = 30.seconds
SolidQueue::ListenNotify.auto_install_trigger = true
```

The two are equivalent — `config.solid_queue_listen_notify` is copied onto the module by an initializer. An unknown option name is logged as a warning and ignored rather than raising; a typo in an optional optimization shouldn't stop an app from booting.

| Option | Default | What it does |
|---|---|---|
| `enabled` | `true`, unless `SOLID_QUEUE_LISTEN_NOTIFY_ENABLED` is set to the literal string `"false"` | Master switch. When off, the preflight returns immediately with reason `:disabled`, nothing is registered, no connection is opened, and polling intervals are untouched. The environment variable is read once, when the gem is loaded, and **only the exact value `"false"` disables it** — `"0"`, `"no"` and `"off"` all leave the gem enabled. |
| `channel` | `"solid_queue_ready"` | The `pg_notify` channel. Must be **1 to 63 bytes** — Postgres's identifier limit — and must match what the installed trigger notifies on. The preflight checks the length before it opens a connection, and looks in the trigger's function body for the exact `pg_notify('<channel>', NEW.queue_name)` call to detect drift. |
| `fallback_polling_interval` | `10.seconds` | The polling interval workers are raised to once notifications are proven to work. **Only ever raises**: a worker already configured to poll every 30 seconds keeps its 30 seconds, and a worker at 0.1 goes to 10. Set to `nil` to never touch any worker's interval. Applied only when the gem is operational, and put back if registration then fails. |
| `listen_database` | `nil` | Name of a `config/database.yml` entry to open the listener connection against, instead of Solid Queue's own pool. This is the PgBouncer escape hatch: point it at an entry that connects **directly** to Postgres. It must name **the same database** as the queue database — only the connection route may differ — and the preflight's self-test fails if it doesn't. It gets a private connection handler, so it never mixes with your application's pools. |
| `auto_install_trigger` | `false` | When the preflight finds the trigger missing, install it there and then. Idempotent, but it needs a database user allowed to create functions and triggers, and a failure is treated as "still missing" (you get the install instructions, not a stack trace). The cure for the schema.rb trap described [below](#schemarb-does-not-dump-triggers). |
| `wake_saturated_workers` | `false` | By default a worker whose thread pool has no idle thread is skipped: it has nothing to do with the wake-up, and its pool's own `on_idle` hook plus polling cover the race. Set to `true` to wake it anyway. |
| `wait_timeout` | `1.second` | How long each `wait_for_notify` call blocks before looping. Also the granularity at which the listener notices it has been asked to stop, and (times two, plus one) the join timeout on shutdown — which is what keeps it inside Solid Queue's 5-second shutdown timeout. |
| `keepalive_interval` | `10.seconds` | How often the listener runs `SELECT 1` on its connection, to notice a silently dropped connection and to keep idle-connection reapers away. Each tick also sweeps workers that went away without a stop hook. |
| `reconnect_wait` | `5.seconds` | Backoff between reconnection attempts after a connection error. Slept in `wait_timeout`-sized slices so that a shutdown is never delayed by a full backoff. |
| `connection_errors_reporting_threshold` | `6` | Consecutive connection failures before errors start being reported to `SolidQueue.on_thread_error` (and logged at `ERROR` rather than `WARN`). With the defaults that is roughly 30 seconds of failing before your exception tracker hears about it, which keeps a rolling database restart from paging anyone. The counter resets on every **successful connect**, as well as on the first notification or keepalive after one — so a connection that flaps faster than `keepalive_interval` cannot climb past the threshold once and then report forever. |
| `application_name` | `"solid_queue-listen_notify [<pid>]"` | The `application_name` the listener sets on its connection, so you can find it in `pg_stat_activity`. The default is resolved on every call, so a process that forks after boot reports its own pid. |
| `connection_provider` | `SolidQueue::ListenNotify::ConnectionProvider.new` | **Advanced.** Anything responding to `#call` that returns a pool-removed Postgres connection. Replace it only if you need to hand the listener a connection nothing else could produce; the default already handles the writing-role pin and `listen_database`. |

## What you'll see in the logs

Everything goes through `SolidQueue.logger` (with a `$stdout` fallback, so the warnings can't be lost when Solid Queue isn't loaded yet), formatted like Solid Queue's own log subscriber so a single log reads as one stream:

```
SolidQueue-ListenNotify-0.1.0 Preflight passed (32.7ms)  channel: "solid_queue_ready", operational: true, reason: nil
SolidQueue-ListenNotify-0.1.0 Raised polling interval (0.0ms)  worker_name: "worker-9a1f0c6b3e8d7c2a5b41", from: 0.1, to: 10.0
SolidQueue-ListenNotify-0.1.0 Started listener (1.2ms)  pid: 51234, channel: "solid_queue_ready"
SolidQueue-ListenNotify-0.1.0 Notification (0.3ms)  queue_name: "background", woken: 1, skipped_saturated: 0
SolidQueue-ListenNotify-0.1.0 Keepalive (0.4ms)  pid: 51234
SolidQueue-ListenNotify-0.1.0 Stopped listener (0.1ms)  pid: 51234
```

`Notification` and `Keepalive` are logged at `DEBUG`, because they happen constantly. At `INFO` you see the preflight verdict, the listener starting and stopping, any polling interval that was raised, and the trigger being installed. Anything that means "this is degraded" is at least a warning:

```
SolidQueue-ListenNotify-0.1.0 Preflight failed – the gem is inactive (18.4ms)  channel: "solid_queue_ready", operational: false, reason: :trigger_missing
SolidQueue-ListenNotify-0.1.0 Listener connection lost – reconnecting (0.2ms)  error: "PG::ConnectionBad", message: "PQconsumeInput() server closed the connection unexpectedly", consecutive_failures: 1, wait: 5 seconds
SolidQueue-ListenNotify-0.1.0 Fork detected – discarding the inherited listener (0.1ms)  parent_pid: 51234, pid: 51299
SolidQueue-ListenNotify-0.1.0 Listener died (0.1ms)  pid: 51234, error: "NotImplementedError", message: "No connection provider configured..."
SolidQueue-ListenNotify listener died permanently (NotImplementedError: No connection provider configured...); 2 worker(s) restored to their original polling intervals. Notifications are no longer being delivered in this process — it is back to plain polling.
SolidQueue-ListenNotify-0.1.0 Restored polling interval (0.0ms)  worker_name: "worker-9a1f0c6b3e8d7c2a5b41", from: 10.0, to: 0.1
```

A failing preflight also prints a multi-line banner explaining what is wrong and how to fix it. That banner is written by the preflight itself, not by the log subscriber, so it comes out even in a process where no subscriber was ever attached.

### Instrumentation events

All events are on `ActiveSupport::Notifications` with the suffix `.solid_queue_listen_notify`, so `preflight.solid_queue_listen_notify`, `notify.solid_queue_listen_notify`, and so on.

| Event | Payload | When |
|---|---|---|
| `preflight` | `channel:`, `operational:`, `reason:`, `details:` (only when there are any) | Once per process, the first time `operational?` is asked. `reason` is `nil` on success, otherwise one of `:disabled`, `:invalid_channel`, `:unsupported_adapter`, `:trigger_missing`, `:channel_mismatch`, `:self_test_failed`, `:error`. |
| `start_listener` | `pid:`, `channel:` | The listener connected and issued its `LISTEN`. Also fires on every reconnect. (It is not called `start`: `ActiveSupport::Subscriber` reserves that name for the notifier protocol.) |
| `notify` | `queue_name:`, `woken:`, `skipped_saturated:` | A notification arrived and was fanned out. `queue_name` is the payload, i.e. the queue the job was enqueued on. |
| `keepalive` | `pid:` | A `SELECT 1` tick, every `keepalive_interval`. |
| `reconnect` | `error:`, `message:`, `consecutive_failures:`, `reported:`, `wait:` | A connection error was caught. `reported: true` means the failure count exceeded `connection_errors_reporting_threshold` and the error was handed to `SolidQueue.on_thread_error`. |
| `install_trigger` | `channel:`, `database_version:` | The trigger was installed — by `auto_install_trigger`, or by anything else calling `TriggerInstaller#install!`. `database_version` is Postgres's integer version (e.g. `150001`). |
| `fork_detected` | `parent_pid:`, `pid:` | A registry entry point ran in a process that inherited a listener from its parent. Logged at `WARN`: see [the fork caveat](#puma-clustered--async-is-discouraged). |
| `shutdown` | `pid:`, plus `error:` and `message:` when it died | The listener thread finished, whether cleanly or not. |
| `override_polling_interval` | `worker_name:`, `from:`, `to:`, `restored:` (only on the way back) | A worker's polling interval was raised to `fallback_polling_interval`. Never emitted when the gem is not operational. The same event with `restored: true` means the listener died for good and the worker was put back on its original interval. |

## Failure modes

The table below is the whole safety story. In every row the outcome is "stock Solid Queue" — polling at the interval you configured — and in every row you are told about it.

| Situation | What the gem does |
|---|---|
| **Trigger missing** | Preflight fails with `:trigger_missing` and prints a banner with the exact generator command. Not operational, polling intervals untouched. With `auto_install_trigger = true` it tries to install the trigger first, and only reports missing if that fails too (the failure is included in the banner). |
| **Non-Postgres adapter** | Detected from the queue pool's configuration, without opening a connection at all. An adapter that *is* named Postgres but whose raw connection can't `wait_for_notify` is caught right after. Either way, a prominent banner names the adapter it found and tells you to remove the gem or move the queue database to Postgres. Not operational. |
| **Postgres down at boot** | Every branch of the preflight is rescued: the exception becomes an `:error` verdict with its class and message in the payload. `bin/jobs` starts normally and workers poll. The verdict is per-process and memoized, so a database that comes back later is picked up by the next process, not this one. |
| **Connection drops mid-run** | The listener catches `PG::Error`, `ActiveRecord::ConnectionNotEstablished`, `ActiveRecord::ConnectionFailed`, `ActiveRecord::StatementInvalid`, `IOError`, `EOFError`, `Errno::EPIPE` and `Errno::ECONNRESET`, disconnects, waits `reconnect_wait`, and reconnects — indefinitely. The first failures are `WARN`-level only; after `connection_errors_reporting_threshold` consecutive ones they escalate to `ERROR` and go to `SolidQueue.on_thread_error`. Meanwhile polling still runs the jobs. |
| **Listener dies for good** | A fatal, non-connection error (API drift, a connection provider that cannot be configured) kills the listener thread, and no reconnect will fix it. The gem raised those workers' polling intervals on the strength of a promise it can no longer keep, so it withdraws the promise: the registry detaches the dead listener, every interval this gem raised is put back, each worker is `wake_up`ped so it re-reads it instead of finishing its 10-second sleep, and one `ERROR` line says the listener died permanently and how many workers were restored. Back to stock Solid Queue at the interval you configured. |
| **A subscriber of ours raises** | Your `ActiveSupport::Notifications` subscribers run on the listener thread. A raising subscriber is caught, reported once per exception class, and the loop carries on — the notification it was subscribed to has already been fanned out. An exception from the gem's own work inside an instrumented block is *not* swallowed: a connection error in a keepalive still reaches the reconnect path. |
| **PgBouncer / transaction pooling** | Transaction-mode pooling silently discards `LISTEN`, and cannot be detected by asking. So the preflight does the only reliable thing: it `LISTEN`s on the very connection the listener would use, sends a `NOTIFY` on the real channel **from a pooled connection to the queue database** — the connection the trigger itself would fire on — and waits 2 seconds for it to arrive. Failure prints an `ERROR` banner naming PgBouncer explicitly and telling you to set `listen_database`. Because the two halves run on different connections, the same test also catches a `listen_database` pointing at a reachable but *wrong* database, and the banner says so. It additionally runs `SELECT pg_backend_pid()` twice on one connection; if the answers differ, the banner adds that you are almost certainly behind a transaction-mode pooler. Not operational. |
| **Channel Postgres can't accept** | Notification channels are identifiers, capped at 63 bytes. `LISTEN`/`NOTIFY` truncate a longer one *silently*, but the trigger's `pg_notify()` takes it as text and raises `channel name too long` — on every insert into `solid_queue_ready_executions`, which is to say on every enqueue in your application. So the length is checked in three places: the generator refuses to write the migration, `TriggerInstaller#install!` raises rather than installing, and the preflight fails with `:invalid_channel` and a banner before it opens a single connection. |
| **`SIGQUIT` / `exit!`** | `on_worker_stop` is not guaranteed to run — a supervisor past its shutdown timeout calls `exit!` and skips every callback. Nothing here depends on it. The listener's connection dies with the process, and inside a surviving process the registry reaps workers that are no longer `alive?` on every register and every keepalive tick — and drops any worker whose `wake_up` raises while a notification is being fanned out. The listener stops itself when the last worker goes, and that stop does **not** join the listener thread: a worker gets five seconds to shut down in total, and the thread unwinds and closes its own connection within one `wait_timeout` without being waited on. |
| **`fork` after the listener started** | The listener's connection was removed from its pool, so Active Record's own `discard_pools!` cannot see it. A `ForkTracker.after_fork` hook plus a pid check at every registry entry point catches this: in the child, the inherited connection is `discard!`ed (which drops our end of the file descriptor — never `disconnect!`, which would send a termination packet down the **parent's** session), the registry is emptied, and `fork_detected` is logged at `WARN`. The child gets a clean listener of its own the first time a worker registers. |
| **`fork` while a lock was held** | `fork()` copies only the calling thread, so any lock another thread was holding is inherited with nobody left to release it. CRuby abandons those mutexes itself, so this is not a live hang today — but the exposure is asymmetric (the widest window is `operational?`, which holds a lock across connecting to Postgres and a two-second self-test, and a child that inherited it would hang the first worker to register, silently, inside a lifecycle hook), so the `after_fork` hook **replaces** every lock in the gem while the child is still single-threaded rather than relying on an interpreter detail. The same hook makes the connection provider forget any pool it memoized for `listen_database`, because Active Record discarded that pool in the child behind our back and the first checkout from it would raise. |
| **Saturated workers** | A worker with no idle thread is skipped and counted in the `notify` event's `skipped_saturated`. Its pool wakes it itself when a thread frees up, and polling is still there. `wake_saturated_workers = true` opts out. |
| **Paused queues** | Notifications are routed by queue name only, with no database lookup, so a worker on a paused queue is woken. It claims nothing and goes back to sleep — a wasted wake-up, not a bug. |
| **Replicas** | The listener connection is checked out inside `connected_to(role: :writing)`. A `LISTEN` on a replica hears nothing, so this is not optional. |
| **Gem removed, trigger left behind** | The trigger keeps firing `pg_notify` with nobody listening, which costs a function call per inserted row and nothing else. Run the migration's `down` when you want it gone. |

## Important caveats

### schema.rb does not dump triggers

This is the trap most likely to bite you. `ActiveRecord::Base.schema_format = :ruby` — the default — dumps tables, indexes and columns, and **not** triggers. So a database created with `db:schema:load` (a fresh CI database, a new developer's machine, a restored staging environment) has the table but not the trigger, and the gem correctly refuses to activate. There are three ways out, in increasing order of how much you have to remember:

1. Set `auto_install_trigger = true` and let the preflight put the trigger back whenever it is missing. This is the recommended option, and it needs a database user allowed to `CREATE FUNCTION` and `CREATE TRIGGER`.
2. Use `schema_format = :sql` for the queue database, so `structure.sql` carries the trigger. Rails 8.0 and later accept a per-entry `schema_format: sql` in `config/database.yml`; on 7.1 and 7.2 it is `ActiveRecord.schema_format` for the whole application or nothing.
3. Run migrations rather than loading the schema on every fresh environment.

Either way, the failure is loud: a database without the trigger produces the `:trigger_missing` banner when a worker process starts, not silence.

### PgBouncer and other transaction-mode poolers

`LISTEN` is a session-level statement. A transaction-mode pooler hands your session back to the pool at the end of every transaction, so a `LISTEN` issued through it applies to whichever backend happened to serve that statement, and notifications go nowhere. Session-mode pooling is fine; transaction mode is not.

The preflight's self-test detects this and refuses to activate, so you get an error banner instead of a silent latency regression. The fix is `listen_database`: add an entry to `config/database.yml` that connects straight to Postgres, bypassing the pooler, and name it there. That entry is used for the listener connection only — one connection per worker process — while everything else keeps going through the pooler.

It has to point at **the same database**, with only the route differing. An entry naming a different database connects and `LISTEN`s perfectly happily and then never hears a thing, which is exactly the kind of silent failure this gem exists not to have — so the self-test spans both connections and catches it, and the banner tells you to check for it.

### Puma clustered + `async` is discouraged

Running Solid Queue inside Puma with `solid_queue_mode :async` **and** Puma in clustered mode (`workers > 0`) means the listener's dedicated connection can be inherited across `fork`. The gem handles this — see the fork row in the table above, and there is an integration test that forks a live listener and asserts the parent's `pg_stat_activity` session survives the child exiting — but you are relying on a guard rather than on the problem not existing.

Solid Queue's own advice applies here too: the recommended and default mode is `fork`. Prefer the Puma plugin in its default fork mode, or run `bin/jobs` as its own process. If you must run clustered Puma with `solid_queue_mode :async`, watch for `Fork detected` warnings in the log — they are at `WARN` precisely so you can.

### Scheduled and recurring jobs are still bound by the dispatcher

This gem accelerates one thing: the moment a row appears in `solid_queue_ready_executions`. Jobs enqueued with `set(wait:)` or `wait_until:`, and recurring tasks, sit in `solid_queue_scheduled_executions` until the **dispatcher** polls, finds them due, and moves them across — at which point the trigger fires and the pickup is instant. The dispatcher's own `polling_interval` (1 second by default) is therefore the floor for delayed jobs, and raising it slows them down. Raise worker polling intervals freely; leave the dispatcher's alone.

### The preflight sends one real notification at boot

The self-test `LISTEN`s on the connection the listener will use, then sends a `NOTIFY` on the configured channel, with the payload `"preflight"`, **from a pooled connection to the queue database** — the same connection route the trigger's own notifications take. Testing the real channel over the real path is the point; anything narrower would test a different code path.

It does mean every other worker process listening on that channel receives it too. Those processes fan out a notification for a queue named `preflight`: workers listening on `*` (or on a prefix that happens to match) wake up, find nothing, and go back to sleep. It costs one spurious wake-up per running worker process per new process started, and nothing else.

### One extra connection per worker process

The listener holds a direct Postgres connection for the lifetime of the process, outside the Active Record pool it came from. In `fork` mode that is one connection per worker process; in `async` mode, one for the whole supervisor. Budget for it in `max_connections` — and remember that the preflight briefly opens (and closes) one of its own before the listener does.

## Designed to be deletable

Nothing about this gem is load-bearing, and getting rid of it should take five minutes:

1. Remove `solid_queue-listen_notify` from your `Gemfile`.
2. Lower `polling_interval` in `config/queue.yml` back to something you're happy with as the *only* pickup path.
3. Drop the trigger, either by reverting the generated migration (`bin/rails db:migrate:down:queue VERSION=20260727120000`, using the name you passed to `--database`) or with two statements:

   ```sql
   DROP TRIGGER IF EXISTS solid_queue_listen_notify ON solid_queue_ready_executions;
   DROP FUNCTION IF EXISTS solid_queue_listen_notify_ready();
   ```

Step 3 is optional and can wait: a trigger notifying a channel nobody listens on is harmless. And if you only want to turn the gem off without deploying, set `SOLID_QUEUE_LISTEN_NOTIFY_ENABLED=false` and restart your workers.

## Development and testing

The test suite needs a Postgres it can `LISTEN` on. There's a compose file for one:

```bash
docker compose up -d
bin/setup
bundle exec rake test
```

If you already run Postgres locally, skip Docker entirely — the dummy app reads `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER` and `POSTGRES_PASSWORD`, and defaults to what the compose file publishes (`127.0.0.1:55432`, user `postgres`):

```bash
POSTGRES_PORT=5432 POSTGRES_USER=$(whoami) bin/setup
POSTGRES_PORT=5432 POSTGRES_USER=$(whoami) bundle exec rake test
```

Three tasks:

- `rake test:unit` — no database, no Rails application. Everything in the gem that can be tested without Postgres is tested here.
- `rake test:integration` — boots `test/dummy` against a real Postgres and runs real workers. Non-transactional by necessity: Postgres delivers notifications on commit, and a transactional test never commits.
- `rake test` — both.

`bundle exec rubocop` for style ([rubocop-rails-omakase](https://github.com/rails/rubocop-rails-omakase)). CI tests the edges rather than a full grid: Ruby 3.2 × Rails 7.1 (oldest supported), Ruby 3.4 and 4.0 × Rails 8.1 (newest), plus an allowed-to-fail cell against `solid_queue@main` for early warning on upstream drift. `bundle exec appraisal generate` regenerates `gemfiles/` after a change to `Appraisals`, and `BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile bundle exec rake test` runs a single combination locally.

## Contributing

Bug reports and pull requests are welcome at https://github.com/cmer/solid_queue-listen_notify — please include a failing test where it makes sense.

## License

The gem is available as open source under the terms of the [MIT License](MIT-LICENSE).

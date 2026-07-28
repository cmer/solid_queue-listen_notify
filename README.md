# solid_queue-listen_notify

Instant job pickup for [Solid Queue](https://github.com/rails/solid_queue) on Postgres — without the polling tax.

Out of the box, every Solid Queue worker polls the database for work every 0.1 seconds, forever, whether or not there is anything to do. This gem replaces the waiting with Postgres's native LISTEN/NOTIFY: a database trigger announces the moment a job becomes ready, and workers wake instantly instead of polling for it.

## Why

- **Near-instant pickup.** Enqueue-to-start drops to ~50–60 ms (measured locally) even with workers polling once a minute.
- **Orders of magnitude less database load.** Polling can be raised from 10 queries/second per worker to once every 10–60 seconds, because it no longer has to be fast — just present.
- **Safe by design.** Polling stays as the correctness backstop. If anything is wrong — trigger missing, database down, a pooler eating the `LISTEN`, connection dropped — the gem says so loudly in the log, deactivates itself, and you are running stock Solid Queue.
- **No patches.** Solid Queue is untouched: the gem uses only its documented lifecycle hooks and public APIs, and it can be [removed in five minutes](#uninstalling).

## Requirements

PostgreSQL 12+ (for the queue database only), Solid Queue 1.5+, Rails 7.1+, Ruby 3.2+.

## Installation

```bash
bundle add solid_queue-listen_notify
bin/rails generate solid_queue:listen_notify:install --database queue
bin/rails db:migrate
```

Then run `bin/jobs` as before. There is nothing to start: the gem hooks into Solid Queue's worker lifecycle, verifies at boot that notifications actually get delivered, and only then raises the workers' polling interval (0.1 s → 10 s by default).

The `--database` option names the `config/database.yml` entry Solid Queue uses — `queue` is Solid Queue's own default. If your jobs live in the primary database, use `--database primary`.

The migration is a formality: the gem also reinstalls the trigger by itself at boot whenever it's missing (`schema.rb` doesn't dump triggers, so a fresh `db:schema:load` database would otherwise lack it). If your database user isn't allowed to create functions and triggers, the migration is the way — and set `auto_install_trigger = false` to silence the attempt.

## How it works

An `AFTER INSERT` trigger on `solid_queue_ready_executions` calls `pg_notify` with the queue name — covering every path that makes a job ready, since they all end in an insert on that table. Postgres delivers notifications on commit and de-duplicates within a transaction, so a bulk enqueue of 500 jobs sends one notification and a rolled-back enqueue sends none.

In each worker process, one listener thread on one dedicated connection receives the notifications and wakes the workers whose queues match, using Solid Queue's own public `wake_up`. If the connection drops, the listener reconnects with backoff while polling covers the gap.

## Configuration

The defaults are right for most apps. The options you're most likely to touch:

| Option | Default | What it does |
|---|---|---|
| `fallback_polling_interval` | `10.seconds` | What workers' `polling_interval` is raised to once notifications are verified. Only ever raises; `nil` to leave intervals alone. |
| `listen_database` | `nil` | A `database.yml` entry that connects **directly** to Postgres, for apps behind PgBouncer in transaction mode (which silently breaks `LISTEN` — the gem detects this at boot and tells you). |
| `enabled` | `true` | Kill switch; also `SOLID_QUEUE_LISTEN_NOTIFY_ENABLED=false` in the environment, no deploy needed. |

Set them in an initializer as above, or via `config.solid_queue_listen_notify.*` in your Rails config. The full list of options, log output, instrumentation events, and the complete failure-mode reference live in [docs/REFERENCE.md](docs/REFERENCE.md).

## Good to know

- **Scheduled and recurring jobs** still wait on Solid Queue's dispatcher (1 s polling by default) to become ready; only the ready-to-running hop is accelerated. Leave the dispatcher's interval alone.
- **One extra Postgres connection** per worker process, held by the listener. Budget for it in `max_connections`.
- **Puma in clustered mode with `solid_queue_mode :async`** is discouraged (a forked child can inherit the listener's connection — the gem guards against it, but prefer fork mode or standalone `bin/jobs`).
- Workers on paused or non-matching queues, saturated pools, replicas, `SIGQUIT` teardown — all handled; see the [failure-mode reference](docs/REFERENCE.md#failure-modes).

## Uninstalling

Remove the gem, lower `polling_interval` in `config/queue.yml` back to your liking, and (optionally) drop the trigger:

```sql
DROP TRIGGER IF EXISTS solid_queue_listen_notify ON solid_queue_ready_executions;
DROP FUNCTION IF EXISTS solid_queue_listen_notify_ready();
```

A leftover trigger notifying a channel nobody listens on is harmless.

## Development

The suite needs a real Postgres (`LISTEN` can't be faked): `docker compose up -d && bin/setup && bundle exec rake test`, or point `POSTGRES_HOST`/`POSTGRES_PORT`/`POSTGRES_USER`/`POSTGRES_PASSWORD` at your own server. `rake test:unit` runs without any database. See [docs/REFERENCE.md](docs/REFERENCE.md#development-and-testing) for details.

## Credits

The listener's design — a dedicated connection checked out of the Active Record pool and removed from it, short `wait_for_notify` slices, keepalives, and patient reconnection — is closely inspired by [GoodJob](https://github.com/bensheldon/good_job)'s notifier, which pioneered LISTEN/NOTIFY for Postgres-backed Active Job backends. Thank you, Ben Sheldon and GoodJob contributors.

## Contributing

Bug reports and pull requests are welcome at https://github.com/cmer/solid_queue-listen_notify — please include a failing test where it makes sense.

## License

Open source under the terms of the [MIT License](MIT-LICENSE).

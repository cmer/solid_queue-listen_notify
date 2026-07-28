# Agent instructions: install solid_queue-listen_notify

You are working inside a user's Ruby on Rails application. Your task is to install and verify the `solid_queue-listen_notify` gem, which adds Postgres LISTEN/NOTIFY wake-ups to Solid Queue so workers pick up jobs near-instantly while polling far less often.

Follow the phases in order. Each phase has explicit STOP conditions — when you hit one, stop, explain the situation to the user in plain language, and do not continue guessing. Do not commit anything unless the user asks you to.

## Phase 1 — Verify the prerequisites

Run these checks and collect the answers before changing anything.

1. **This is a Rails application.** There is a `Gemfile` and a `config/application.rb`. If not, STOP: this gem only works inside a Rails app.

2. **Solid Queue is installed and in use.** All of the following should hold:
   - `solid_queue` appears in `Gemfile.lock`.
   - The Active Job adapter is Solid Queue: search `config/` for `queue_adapter` and expect `:solid_queue` (typically `config.active_job.queue_adapter = :solid_queue` in `application.rb` or an environment file).
   - There is Solid Queue configuration: a `config/queue.yml` (or `config/solid_queue.yml` in older setups), and Solid Queue tables in a schema file (look for `solid_queue_ready_executions` in `db/queue_schema.rb`, `db/schema.rb`, or `db/structure.sql`).

   If Solid Queue is not installed, STOP: tell the user to install Solid Queue first (https://github.com/rails/solid_queue) and that this gem is an add-on, not a replacement.

3. **Solid Queue is version 1.5 or newer.** Check the version in `Gemfile.lock`. If older, STOP and tell the user to upgrade Solid Queue to >= 1.5 first (this gem's gemspec requires it).

4. **Identify which database Solid Queue uses.** Search `config/application.rb` and `config/environments/*.rb` for `config.solid_queue.connects_to`. Two cases:
   - Found, e.g. `{ database: { writing: :queue } }` → Solid Queue uses the `config/database.yml` entry named there (commonly `queue`). Remember that name; call it `QUEUE_DB`.
   - Not found → Solid Queue shares the primary database. `QUEUE_DB` is `primary`.

5. **The Solid Queue database is PostgreSQL.** Open `config/database.yml` and find the adapter for `QUEUE_DB` (follow YAML anchors/`<<: *default` and ERB as needed; a `DATABASE_URL` starting with `postgres://`/`postgresql://` also counts). If the adapter is not PostgreSQL (e.g. `mysql2`, `trilogy`, `sqlite3`), STOP: this gem is Postgres-only. Tell the user which adapter you found and that nothing was changed. Only the Solid Queue database matters — the primary database may be anything if Solid Queue has its own.

6. **Check for a connection pooler (best effort).** Look at the `QUEUE_DB` entry's host/port and any `DATABASE_URL`-style env vars referenced. Signs of PgBouncer or another transaction-mode pooler: port 6432, "pgbouncer"/"pooler" in the host name, or documentation/comments saying so. This is not a STOP — the gem detects the problem itself at boot — but note it: you may need Phase 4's `listen_database` step, and you should mention it in your final report.

7. **Ruby is >= 3.2 and Rails is >= 7.1** (check `Gemfile.lock` / `.ruby-version`). If not, STOP and report.

## Phase 2 — Install the gem

Add the gem:

```bash
bundle add solid_queue-listen_notify
```

That is normally the entire install: the gem creates its database trigger automatically the first time it runs (`auto_install_trigger` defaults to `true`), and Phase 3 verifies it. Do NOT run the generator or create an initializer yet — those are fallbacks that Phase 3 will tell you whether you need.

Sensible defaults apply: workers' `polling_interval` is automatically raised to 10 seconds once notifications are verified working, and never touched if they are not.

## Phase 3 — Verify

1. Boot-level verification (this runs the gem's real preflight: adapter check, trigger check with automatic installation, and a live NOTIFY round-trip on the actual database):

   ```bash
   bin/rails runner 'puts SolidQueue::ListenNotify.operational? ? "OPERATIONAL" : "NOT OPERATIONAL — check the log output above"'
   ```

   - `OPERATIONAL` → the install works end to end. Continue to Phase 5.
   - `NOT OPERATIONAL` → the same output includes a banner explaining exactly why. Two actionable cases:
     - The banner reports the trigger missing with an install failure like **"permission denied"** → the database user lacks DDL privileges, so install the trigger through a migration instead (this is what the generator is for):

       ```bash
       bin/rails generate solid_queue:listen_notify:install --database <QUEUE_DB>
       bin/rails db:migrate
       ```

       Also create `config/initializers/solid_queue_listen_notify.rb` with `SolidQueue::ListenNotify.auto_install_trigger = false` so the gem stops attempting DDL it isn't allowed, then re-run the verification. (Caveat for this setup: with `schema_format :ruby` — the default — `schema.rb` does not carry triggers, so databases built with `db:schema:load` need migrations or `structure.sql` to get it.)
     - The banner names PgBouncer / transaction pooling → go to Phase 4.

     Anything else: fix what the banner says and re-run; don't improvise.

2. If the application has a test suite, run it (or at least any job/queue-related tests) to confirm nothing regressed. The gem changes no application behavior — jobs run exactly as before, just picked up sooner — so failures here are unlikely but worth catching.

3. Optional live check, if the user wants to see it: start `bin/jobs` in one terminal, enqueue any job from `bin/rails console` in another, and observe the job starting within well under a second. The log line `SolidQueue-ListenNotify-… Started listener` confirms the listener is up.

## Phase 4 — Only if the self-test reported a pooler

If (and only if) the preflight banner said notifications are not being delivered and suspects PgBouncer/transaction pooling:

1. Add an entry to `config/database.yml` that connects **directly** to Postgres — same database, same credentials, but bypassing the pooler (typically the real host/port instead of the pooler's). Name it e.g. `queue_direct`, inheriting from the queue entry:

   ```yaml
   queue_direct:
     <<: *default            # or copy the queue entry's settings
     host: <the real postgres host>
     port: 5432
     database: <same database name as QUEUE_DB>
   ```

2. Create `config/initializers/solid_queue_listen_notify.rb`:

   ```ruby
   SolidQueue::ListenNotify.listen_database = "queue_direct"
   ```

3. Re-run the Phase 3 verification. Only the single listener connection per worker process uses this direct route; everything else keeps going through the pooler.

If you cannot determine the direct connection details, STOP and ask the user for them — do not guess hosts or ports.

## Phase 5 — Report

Tell the user, concisely:
- What was verified in Phase 1 (Solid Queue version, which database entry, PostgreSQL confirmed).
- What was added: the gem, the migration (its path), and any initializer.
- The verification result (`OPERATIONAL` or what remains to fix).
- That nothing else changed: polling remains the safety net, their configured `polling_interval` values in `config/queue.yml` were not edited, and removal instructions live at https://github.com/cmer/solid_queue-listen_notify#uninstalling.
- Anything you noticed for them to consider (pooler suspicion from Phase 1.6, unusually low/high polling intervals in `queue.yml`).

Do not commit; leave the diff for the user to review.

# Agent instructions: uninstall solid_queue-listen_notify

You are working inside a user's Ruby on Rails application. Your task is to cleanly remove the `solid_queue-listen_notify` gem: drop its database trigger via a migration, remove the gem and its configuration, and leave Solid Queue running on plain polling exactly as it did before the gem was installed.

Follow the phases in order. Stop and ask the user when something doesn't match the expectations below. Do not commit anything unless the user asks you to.

## Phase 1 — Confirm what is installed

1. Confirm `solid_queue-listen_notify` appears in the `Gemfile` (and `Gemfile.lock`). If it doesn't, STOP and tell the user there is nothing to uninstall.

2. Identify which database Solid Queue uses: search `config/application.rb` and `config/environments/*.rb` for `config.solid_queue.connects_to`. If it names a database entry (commonly `queue`), call it `QUEUE_DB`; otherwise `QUEUE_DB` is `primary`.

3. Find the gem's footprint, so the removal is complete:
   - The install migration: search the app's migration directories (`db/migrate/`, `db/queue_migrate/`, or whatever `migrations_paths` `QUEUE_DB` uses) for a file matching `*install_solid_queue_listen_notify_trigger*`. It may not exist (the trigger can also have been installed automatically at boot) — that's fine, note it.
   - Any initializer: `config/initializers/solid_queue_listen_notify*.rb`.
   - Any `config.solid_queue_listen_notify.*` lines in `config/application.rb` or `config/environments/*.rb`.
   - Any custom channel: if configuration sets `channel` to something other than the default `"solid_queue_ready"`, note it — the SQL below doesn't depend on the channel, but mention it in your report.
   - Any `listen_database` entry in `config/database.yml` that exists only for this gem (e.g. `queue_direct`) — confirm with the user before removing it; it may be used by other things.

## Phase 2 — Drop the trigger with a migration

Do this FIRST, while the gem is still installed — the migration must run before the gem is gone from the bundle if you want to `db:migrate` in one pass, and the trigger must not outlive the gem only by accident.

1. Generate an empty migration **against the same database the trigger lives in**:

   ```bash
   bin/rails generate migration RemoveSolidQueueListenNotifyTrigger --database <QUEUE_DB>
   ```

   (Omit `--database` when `QUEUE_DB` is `primary`.)

2. Give it this content — literal SQL, no references to the gem, so it keeps working after the gem is removed:

   ```ruby
   class RemoveSolidQueueListenNotifyTrigger < ActiveRecord::Migration[<use the version the generator produced>]
     def up
       execute <<~SQL
         DROP TRIGGER IF EXISTS solid_queue_listen_notify ON solid_queue_ready_executions;
       SQL
       execute <<~SQL
         DROP FUNCTION IF EXISTS solid_queue_listen_notify_ready();
       SQL
     end

     def down
       execute <<~SQL
         CREATE OR REPLACE FUNCTION solid_queue_listen_notify_ready() RETURNS trigger AS $$
         BEGIN
           PERFORM pg_notify('solid_queue_ready', NEW.queue_name);
           RETURN NULL;
         END;
         $$ LANGUAGE plpgsql;
       SQL
       execute <<~SQL
         DROP TRIGGER IF EXISTS solid_queue_listen_notify ON solid_queue_ready_executions;
       SQL
       execute <<~SQL
         CREATE TRIGGER solid_queue_listen_notify
           AFTER INSERT ON solid_queue_ready_executions
           FOR EACH ROW EXECUTE FUNCTION solid_queue_listen_notify_ready();
       SQL
     end
   end
   ```

   If Phase 1 found a custom `channel`, use it in the `down` method's `pg_notify(...)` in place of `solid_queue_ready`.

3. Run it:

   ```bash
   bin/rails db:migrate
   ```

**Ordering caveat:** removing the gem (Phase 3) before this migration has run in an environment is safe — a leftover trigger notifying a channel nobody listens on is harmless — but the reverse is what you're doing here on purpose: trigger first, gem second. Deployments to other environments will run this migration on their next deploy; that's fine either way.

## Phase 3 — Remove the gem and its configuration

1. ```bash
   bundle remove solid_queue-listen_notify
   ```

2. Delete `config/initializers/solid_queue_listen_notify*.rb` if present.

3. Remove any `config.solid_queue_listen_notify.*` lines found in Phase 1.

4. If the user confirmed the `listen_database` entry (e.g. `queue_direct`) exists only for this gem, remove it from `config/database.yml`.

5. Do NOT delete the original install migration file — it is history and its `down` is already superseded by the new migration. Do not touch `schema.rb`/`structure.sql` by hand; `db:migrate` in step 2 already updated them.

## Phase 4 — Restore polling expectations

The gem raised worker polling intervals **at runtime only** — it never edited `config/queue.yml`. But check `config/queue.yml` anyway: if the user manually raised `polling_interval` (e.g. to 30 or 60 seconds) *because* notifications were making latency a non-issue, that interval is now the only pickup path and jobs will wait that long. Flag any `polling_interval` above a few seconds to the user and ask whether to lower it (Solid Queue's default is 0.1).

## Phase 5 — Verify and report

1. `bundle install` succeeds and `git grep -i listen_notify -- ':!log' ':!tmp'` finds no remaining references outside `db/migrate` history and `schema/structure` files' migration-version lists.
2. The app boots: `bin/rails runner 'puts "boots"'`.
3. Confirm the trigger is gone:

   ```bash
   bin/rails runner 'puts ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM pg_trigger WHERE tgname = %q(solid_queue_listen_notify)")'
   ```

   (Run against the queue database's connection if Solid Queue uses a separate one — e.g. `SolidQueue::Record.connection.select_value(...)` works while solid_queue itself is still installed.)
4. If the test suite exists, run it.

Report to the user: the migration you created and ran, what was removed (gem, initializer, config lines), the `queue.yml` polling intervals you flagged, and that everything is left uncommitted for review.

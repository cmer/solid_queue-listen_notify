# frozen_string_literal: true

require "integration_helper"
require "generators/solid_queue/listen_notify/install/install_generator"

# The generator only makes sense against a booted application: `--database`
# resolves through ActiveRecord::Base.configurations to that entry's
# migrations_paths, which is what puts the migration next to Solid Queue's own.
#
# The SQL itself is asserted here only for the things the migration must not
# lose (channel, table, RETURN NULL, both Postgres version paths, a `down` that
# drops the function too). The unit suite already checks it against the
# TriggerInstaller's SQL statement by statement.
class GeneratorTest < Rails::Generators::TestCase
  tests SolidQueue::ListenNotify::Generators::InstallGenerator

  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  MIGRATION = "install_solid_queue_listen_notify_trigger.rb"

  test "writes the migration to the queue database's migrations path by default" do
    run_generator

    assert_migration "db/queue_migrate/#{MIGRATION}"
  end

  test "--database targets that entry's migrations path" do
    run_generator [ "--database", "primary" ]

    assert_migration "db/migrate/#{MIGRATION}"
    assert_no_migration "db/queue_migrate/#{MIGRATION}"
  end

  test "the migration is literal, self-contained SQL" do
    run_generator

    assert_migration "db/queue_migrate/#{MIGRATION}" do |migration|
      assert_match(/class InstallSolidQueueListenNotifyTrigger < ActiveRecord::Migration\[\d+\.\d+\]/, migration)

      # Nothing in here may reference the gem: the migration has to keep
      # replaying on a machine that no longer has it installed.
      assert_no_match(/SolidQueue::ListenNotify/, migration)

      assert_match(/PERFORM pg_notify\('solid_queue_ready', NEW\.queue_name\)/, migration)
      assert_match(/RETURN NULL/, migration)
      assert_match(/AFTER INSERT ON solid_queue_ready_executions/, migration)
      assert_match(/FOR EACH ROW EXECUTE FUNCTION solid_queue_listen_notify_ready\(\)/, migration)

      # CREATE OR REPLACE TRIGGER needs Postgres 14, so both paths ship.
      assert_match(/connection\.database_version >= 14_00_00/, migration)
      assert_match(/CREATE OR REPLACE TRIGGER solid_queue_listen_notify/, migration)

      down = migration.split(/def down/).last
      assert_match(/DROP TRIGGER IF EXISTS solid_queue_listen_notify ON solid_queue_ready_executions/, down)
      assert_match(/DROP FUNCTION IF EXISTS solid_queue_listen_notify_ready\(\)/, down)
    end
  end

  test "the configured channel is baked in at generation time" do
    SolidQueue::ListenNotify.channel = "custom_channel"
    run_generator

    assert_migration "db/queue_migrate/#{MIGRATION}" do |migration|
      assert_match(/pg_notify\('custom_channel', NEW\.queue_name\)/, migration)
    end
  ensure
    SolidQueue::ListenNotify.channel = "solid_queue_ready"
  end

  # Generating a migration that cannot run is worse than refusing to generate
  # one. A channel over Postgres's 63-byte identifier limit would install a
  # trigger whose pg_notify() raises "channel name too long" on every insert into
  # solid_queue_ready_executions — which is to say on every enqueue.
  test "a channel Postgres cannot accept is refused at generation time" do
    SolidQueue::ListenNotify.channel = "a" * 64

    # `debug: true` is what makes Thor re-raise instead of printing the error and
    # returning; either way nothing is written.
    error = assert_raises(Thor::Error) { run_generator([], debug: true) }

    assert_match(/between 1 and 63 bytes/, error.message)
    assert_no_migration "db/queue_migrate/#{MIGRATION}"
  ensure
    SolidQueue::ListenNotify.channel = "solid_queue_ready"
  end

  test "the refusal is reported and writes nothing even when Thor swallows it" do
    SolidQueue::ListenNotify.channel = "a" * 64
    output = capture(:stderr) { run_generator }

    assert_match(/between 1 and 63 bytes/, output)
    assert_no_migration "db/queue_migrate/#{MIGRATION}"
  ensure
    SolidQueue::ListenNotify.channel = "solid_queue_ready"
  end

  test "a channel of exactly 63 bytes still generates" do
    SolidQueue::ListenNotify.channel = "a" * 63
    run_generator

    assert_migration "db/queue_migrate/#{MIGRATION}"
  ensure
    SolidQueue::ListenNotify.channel = "solid_queue_ready"
  end
end

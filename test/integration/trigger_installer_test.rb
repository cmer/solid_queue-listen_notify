# frozen_string_literal: true

require "integration_helper"

# The NOTIFY side, against a real Postgres: does the trigger install cleanly,
# does it fire on the rows Solid Queue actually writes, and does it respect
# transaction boundaries.
#
# The trigger is installed once for the whole run, so anything here that removes
# it puts it back.
class TriggerInstallerTest < IntegrationTestCase
  INSTALLER = SolidQueue::ListenNotify::TriggerInstaller

  test "install! is idempotent" do
    with_queue_connection do |connection|
      installer = trigger_installer(connection)

      installer.install!
      installer.install!

      assert installer.installed?
      assert_includes installer.function_definition, SolidQueue::ListenNotify.channel
    end
  end

  test "uninstall! removes both the trigger and the function" do
    with_queue_connection do |connection|
      installer = trigger_installer(connection)

      installer.uninstall!

      assert_not installer.installed?
      assert_nil installer.function_definition

      installer.install!
      assert installer.installed?
    end
  end

  # installed? used to match pg_class on the bare relation name, which is not
  # schema-qualified: a trigger on ANOTHER schema's copy of the table counted as
  # installed. An application using a schema per tenant would have been told its
  # trigger was in place while every enqueue in that tenant notified nobody.
  test "a trigger on another schema's copy of the table does not count as installed" do
    with_queue_connection do |connection|
      begin
        connection.execute("CREATE SCHEMA listen_notify_probe")
        connection.execute(<<~SQL)
          CREATE TABLE listen_notify_probe.#{INSTALLER::TABLE_NAME} (
            id bigserial primary key, queue_name text not null
          )
        SQL

        original_search_path = connection.select_value("SHOW search_path")

        # The trigger lives on the public table, and only there.
        assert trigger_installer(connection).installed?

        # Now look at the world the way a tenant whose search_path is the other
        # schema does. Same connection, same query, different resolution.
        connection.execute("SET search_path TO listen_notify_probe")

        assert_not trigger_installer(connection).installed?,
          "the trigger belongs to another schema's table entirely"
      ensure
        connection.execute("SET search_path TO #{original_search_path}") if original_search_path
        connection.execute("DROP SCHEMA IF EXISTS listen_notify_probe CASCADE")
      end
    end
  end

  test "installed? is false rather than an error when the table is not there at all" do
    with_queue_connection do |connection|
      original_search_path = connection.select_value("SHOW search_path")

      begin
        connection.execute("CREATE SCHEMA listen_notify_empty")
        connection.execute("SET search_path TO listen_notify_empty")

        assert_not trigger_installer(connection).installed?
      ensure
        connection.execute("SET search_path TO #{original_search_path}") if original_search_path
        connection.execute("DROP SCHEMA IF EXISTS listen_notify_empty CASCADE")
      end
    end
  end

  test "a new ready execution notifies the channel with its queue name" do
    queue = unique_queue("trigger")

    with_listening_connection do |listening|
      create_ready_execution(queue)

      assert_equal queue, wait_for_notify(listening, timeout: 3)
    end
  end

  test "nothing is delivered until the inserting transaction commits" do
    queue = unique_queue("trigger_tx")

    with_listening_connection do |listening|
      SolidQueue::Record.transaction do
        create_ready_execution(queue)

        # Postgres queues notifications until COMMIT. This is the reason every
        # test class here runs with use_transactional_tests = false.
        assert_nil wait_for_notify(listening, timeout: 0.5),
          "a notification was delivered before the transaction committed"
      end

      assert_equal queue, wait_for_notify(listening, timeout: 3)
    end
  end

  test "no trigger means no notification" do
    queue = unique_queue("trigger_absent")
    uninstall_trigger!

    with_listening_connection do |listening|
      create_ready_execution(queue)

      assert_nil wait_for_notify(listening, timeout: 0.5)
    end
  ensure
    install_trigger!
  end
end

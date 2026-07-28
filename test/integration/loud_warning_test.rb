# frozen_string_literal: true

require "integration_helper"

# "Graceful degradation" is only half the requirement. A gem that silently does
# nothing is a gem whose absence you discover months later, from a latency graph.
# Every way this gem can end up inactive has to be impossible to miss in the log.
#
# The unit suite asserts the wording; what this file adds is that the banners
# still come out with the real preflight, the real connection and the real Rails
# logger wiring behind them.
class LoudWarningTest < IntegrationTestCase
  test "a non-postgres adapter gets a banner naming the adapter it found" do
    result = nil
    log = capture_listen_notify_log do
      result = SolidQueue::ListenNotify::Preflight.new(adapter_name: -> { "mysql2" }).run
    end

    assert_not result.operational?
    assert_equal :unsupported_adapter, result.reason
    assert_equal "mysql2", result.details[:adapter]

    assert_includes log, "WARN"
    assert_includes log, "=" * 78
    assert_includes log, "solid_queue-listen_notify requires PostgreSQL. Detected adapter: mysql2."
    assert_includes log, "The gem is INACTIVE — workers will use plain polling."
    assert_includes log, "Remove the gem or switch the queue database to PostgreSQL"
  end

  test "a self-test that never gets its own NOTIFY back blames the pooler at ERROR level" do
    # The self-test runs on the very connection the listener would use, so this
    # is the closest a test on a direct Postgres can get to transaction pooling:
    # a real connection whose wait_for_notify never delivers.
    provider = -> do
      connection = SolidQueue::ListenNotify::ConnectionProvider.new.call
      connection.raw_connection.stubs(:wait_for_notify).returns(nil)
      connection
    end

    result = nil
    log = capture_listen_notify_log do
      result = SolidQueue::ListenNotify::Preflight.new(connection_provider: provider, self_test_timeout: 0.5).run
    end

    assert_not result.operational?
    assert_equal :self_test_failed, result.reason

    assert_includes log, "ERROR"
    assert_includes log, "solid_queue-listen_notify SELF-TEST FAILED"
    assert_includes log, "The most likely cause is PgBouncer"
    assert_includes log, "`SolidQueue::ListenNotify.listen_database`"

    # The backend-pid heuristic only ever ENRICHES the message. This connection
    # really does go straight to Postgres, so it must not fire and must not be
    # mentioned.
    assert_equal false, result.details[:backend_pid_changed]
    assert_not_includes log, "Backend PID changed"
  end

  test "the log subscriber reports a failed preflight, with its reason, on the same logger" do
    events = nil

    log = capture_listen_notify_log do
      events = capture_listen_notify_events(:preflight) do
        SolidQueue::ListenNotify::Preflight.new(adapter_name: -> { "sqlite3" }).run
      end
    end

    payload = events.last.payload
    assert_equal false, payload[:operational]
    assert_equal :unsupported_adapter, payload[:reason]
    assert_equal({ adapter: "sqlite3" }, payload[:details])
    assert_equal SolidQueue::ListenNotify.channel, payload[:channel]

    assert_includes log, "Preflight failed – the gem is inactive"
    assert_includes log, "reason: :unsupported_adapter"
  end

  test "a worker started while the gem is inactive is left completely alone" do
    log = capture_listen_notify_log do
      with_listen_notify_config(enabled: false) do
        SolidQueue::ListenNotify.reset!

        worker = start_worker(queues: unique_queue("inactive"), polling_interval: 0.5)

        assert_equal 0.5, worker.polling_interval
        assert_empty listen_notify_registry.workers
      end
    end

    # Disabled on purpose is the one inactive state that is NOT shouted about.
    assert_not_includes log, "=" * 78
  ensure
    SolidQueue::ListenNotify.reset!
  end
end

# frozen_string_literal: true

require "integration_helper"

# The preflight's decision tree is covered exhaustively by the unit suite with
# every dependency injected. What is left to prove is that the real thing — real
# adapter, real pool-removed connection, real trigger — reaches the same verdicts.
class PreflightIntegrationTest < IntegrationTestCase
  test "a correctly installed setup is operational" do
    assert SolidQueue::ListenNotify.operational?
  end

  test "the verdict is instrumented, and the log subscriber reports it" do
    events = nil

    log = capture_listen_notify_log do
      events = capture_listen_notify_events(:preflight) { assert SolidQueue::ListenNotify.operational? }
    end

    event = events.last
    assert_equal true, event.payload[:operational]
    assert_nil event.payload[:reason]
    assert_equal SolidQueue::ListenNotify.channel, event.payload[:channel]

    assert_includes log, "Preflight passed"
  end

  test "the verdict is memoized per process" do
    events = capture_listen_notify_events(:preflight) do
      3.times { assert SolidQueue::ListenNotify.operational? }
    end

    assert_equal 1, events.size
  end

  test "a missing trigger is not operational and says so loudly" do
    uninstall_trigger!
    SolidQueue::ListenNotify.reset!

    result = nil
    log = capture_listen_notify_log do
      result = capture_listen_notify_events(:preflight) { assert_not SolidQueue::ListenNotify.operational? }.last
    end

    assert_equal :trigger_missing, result.payload[:reason]
    assert_includes log, "the notification trigger is missing from"
    assert_includes log, "bin/rails generate solid_queue:listen_notify:install --database queue"
    assert_includes log, "=" * 78
  ensure
    install_trigger!
    SolidQueue::ListenNotify.reset!
  end

  test "auto_install_trigger installs the missing trigger and the gem comes up operational" do
    uninstall_trigger!
    SolidQueue::ListenNotify.reset!
    assert_not trigger_installed?

    with_listen_notify_config(auto_install_trigger: true) do
      assert SolidQueue::ListenNotify.operational?
      assert trigger_installed?
    end
  ensure
    install_trigger!
    SolidQueue::ListenNotify.reset!
  end

  test "a trigger installed for a different channel is reported as a mismatch" do
    result = nil
    log = nil

    with_listen_notify_config(channel: "some_other_channel") do
      SolidQueue::ListenNotify.reset!

      log = capture_listen_notify_log do
        result = capture_listen_notify_events(:preflight) { assert_not SolidQueue::ListenNotify.operational? }.last
      end
    end

    assert_equal :channel_mismatch, result.payload[:reason]
    assert_includes log, "the installed trigger does not notify on the"
    assert_includes log, '"some_other_channel"'
  ensure
    install_trigger!
    SolidQueue::ListenNotify.reset!
  end

  # The drift check used to ask whether the channel appeared anywhere in the
  # function source. The function is called solid_queue_listen_notify_ready, so
  # for a channel named "ready" (or "notify", or "listen") the check was
  # satisfied by the function's OWN NAME and passed for a trigger notifying
  # something else entirely. This is the same scenario as the test above, run
  # against a real pg_get_functiondef, with the one channel name that used to
  # slip through.
  test "a channel whose name appears in the function's own name is still caught" do
    result = nil
    log = nil

    with_listen_notify_config(channel: "ready") do
      SolidQueue::ListenNotify.reset!

      log = capture_listen_notify_log do
        result = capture_listen_notify_events(:preflight) { assert_not SolidQueue::ListenNotify.operational? }.last
      end
    end

    assert_equal :channel_mismatch, result.payload[:reason]
    assert_includes log, "the installed trigger does not notify on the"
  ensure
    install_trigger!
    SolidQueue::ListenNotify.reset!
  end

  test "the drift check passes against a real pg_get_functiondef for the installed channel" do
    definition = with_queue_connection { |connection| trigger_installer(connection).function_definition }

    assert_includes definition,
      SolidQueue::ListenNotify::TriggerInstaller.notify_call_for(SolidQueue::ListenNotify.channel),
      "pg_get_functiondef renders the body verbatim; the drift check depends on that being true"
    assert SolidQueue::ListenNotify.operational?
  end

  # The self-test now LISTENs on the connection the listener will use and sends
  # the NOTIFY from the pooled queue-database connection the trigger fires on.
  # That is what makes it catch a listen_database pointing at a real, reachable,
  # WRONG database — where the LISTEN succeeds, the NOTIFY succeeds, and nothing
  # ever crosses between them. The old single-connection self-test passed here.
  test "a listen_database pointing at the wrong database fails the self-test" do
    result = nil
    log = nil

    with_listen_notify_config(listen_database: "primary") do
      SolidQueue::ListenNotify.reset!

      log = capture_listen_notify_log do
        result = capture_listen_notify_events(:preflight) { assert_not SolidQueue::ListenNotify.operational? }.last
      end
    end

    assert_equal :self_test_failed, result.payload[:reason]
    assert_includes log, "SELF-TEST FAILED"
    assert_includes log, "If `listen_database` is ALREADY set"
    assert_includes log, "THE SAME database as the queue"
  ensure
    SolidQueue::ListenNotify.reset!
  end

  test "a listen_database pointing at the queue database itself is operational" do
    with_listen_notify_config(listen_database: "queue") do
      SolidQueue::ListenNotify.reset!

      assert SolidQueue::ListenNotify.operational?
    end
  ensure
    SolidQueue::ListenNotify.reset!
  end

  # A >63-byte channel truncates silently in LISTEN/NOTIFY but makes the
  # trigger's pg_notify() raise on every enqueue, so the preflight refuses before
  # it opens a single connection.
  test "a channel Postgres cannot accept is refused before anything connects" do
    result = nil
    log = nil

    with_listen_notify_config(channel: "a" * 64) do
      SolidQueue::ListenNotify.reset!

      log = capture_listen_notify_log do
        result = capture_listen_notify_events(:preflight) { assert_not SolidQueue::ListenNotify.operational? }.last
      end
    end

    assert_equal :invalid_channel, result.payload[:reason]
    assert_includes log, "not a channel name"
    assert_includes log, "channel name too long"
  ensure
    SolidQueue::ListenNotify.reset!
  end

  test "the kill switch skips the preflight entirely" do
    result = nil

    with_listen_notify_config(enabled: false) do
      SolidQueue::ListenNotify.reset!
      result = capture_listen_notify_events(:preflight) { assert_not SolidQueue::ListenNotify.operational? }.last
    end

    assert_equal :disabled, result.payload[:reason]
  ensure
    SolidQueue::ListenNotify.reset!
  end
end

# frozen_string_literal: true

require "test_helper"
require "test_helpers/listener_test_helper"

# The subscriber is where an operator finds out what the gem is doing, so the
# levels matter as much as the text: the two events that happen constantly stay
# at debug, and anything that means "this is degraded" is at least a warning.
class LogSubscriberTest < Minitest::Test
  SUBSCRIBER_CLASS = SolidQueue::ListenNotify::LogSubscriber

  def setup
    @subscriber = SUBSCRIBER_CLASS.new
  end

  def test_a_passing_preflight_is_logged_once_at_info
    log = log_event(:preflight, channel: "solid_queue_ready", operational: true, reason: nil)

    assert_includes log, "INFO"
    assert_includes log, "SolidQueue-ListenNotify"
    assert_includes log, "Preflight passed"
    assert_includes log, %(channel: "solid_queue_ready")
  end

  def test_a_disabled_gem_is_only_mentioned_at_debug
    log = log_event(:preflight, channel: "solid_queue_ready", operational: false, reason: :disabled)

    assert_includes log, "DEBUG"
    assert_includes log, "Preflight skipped"
    refute_includes log, "WARN"
  end

  def test_a_failed_preflight_is_a_warning
    log = log_event(:preflight, channel: "solid_queue_ready", operational: false, reason: :trigger_missing)

    assert_includes log, "WARN"
    assert_includes log, "the gem is inactive"
    assert_includes log, "reason: :trigger_missing"
  end

  def test_notifications_are_logged_at_debug_with_their_counts
    log = log_event(:notify, queue_name: "background", woken: 2, skipped_saturated: 1)

    assert_includes log, "DEBUG"
    assert_includes log, "Notification"
    assert_includes log, %(queue_name: "background")
    assert_includes log, "woken: 2"
    assert_includes log, "skipped_saturated: 1"
  end

  def test_notifications_are_not_logged_at_info
    log = log_event(:notify, level: Logger::INFO, queue_name: "background")

    assert_empty log
  end

  def test_keepalives_are_logged_at_debug
    log = log_event(:keepalive, pid: 42)

    assert_includes log, "DEBUG"
    assert_includes log, "Keepalive"
  end

  def test_an_unreported_reconnect_is_a_warning
    log = log_event(:reconnect, error: "PG::ConnectionBad", message: "server closed the connection",
      consecutive_failures: 1, reported: false, wait: 5)

    assert_includes log, "WARN"
    assert_includes log, "reconnecting"
    assert_includes log, "consecutive_failures: 1"
    refute_includes log, "ERROR"
  end

  def test_a_reported_reconnect_is_an_error
    log = log_event(:reconnect, error: "PG::ConnectionBad", message: "server closed the connection",
      consecutive_failures: 7, reported: true, wait: 5)

    assert_includes log, "ERROR"
    assert_includes log, "consecutive_failures: 7"
  end

  def test_a_clean_shutdown_is_information
    log = log_event(:shutdown, pid: 42)

    assert_includes log, "INFO"
    assert_includes log, "Stopped listener"
  end

  def test_a_shutdown_carrying_an_error_is_an_error
    log = log_event(:shutdown, pid: 42, error: "NotImplementedError", message: "no connection provider")

    assert_includes log, "ERROR"
    assert_includes log, "Listener died"
    assert_includes log, "no connection provider"
  end

  def test_a_fork_is_visible_without_debug_logging
    log = log_event(:fork_detected, parent_pid: 41, pid: 42)

    assert_includes log, "WARN"
    assert_includes log, "Fork detected"
    assert_includes log, "parent_pid: 41"
  end

  def test_the_remaining_events
    assert_includes log_event(:start_listener, pid: 42, channel: "solid_queue_ready"), "Started listener"
    assert_includes log_event(:install_trigger, channel: "solid_queue_ready", database_version: 150_001), "Installed notification trigger"
    assert_includes log_event(:override_polling_interval, worker_name: "worker-1", from: 0.1, to: 10.0), "Raised polling interval"
  end

  # Attaching -------------------------------------------------------------------

  # ActiveSupport::Subscriber silently refuses to subscribe methods named `start`
  # or `finish`, so "the method exists" is not enough: the event has to make it
  # through a real subscription.
  def test_attaching_wires_the_instrumented_events_to_their_methods
    SUBSCRIBER_CLASS.attach_to :solid_queue_listen_notify

    log = capture_listen_notify_log do
      SolidQueue::ListenNotify.instrument(:start_listener, pid: Process.pid, channel: "solid_queue_ready")
      SolidQueue::ListenNotify.instrument(:preflight, channel: "solid_queue_ready", operational: true)
      SolidQueue::ListenNotify.instrument(:notify, queue_name: "background", woken: 1)
    end

    assert_includes log, "Started listener"
    assert_includes log, "Preflight passed"
    assert_includes log, "Notification"
  ensure
    SUBSCRIBER_CLASS.detach_from :solid_queue_listen_notify
  end

  private
    def log_event(name, level: Logger::DEBUG, **payload)
      capture_listen_notify_log(level: level) do
        @subscriber.public_send(name, build_event(name, payload))
      end
    end

    def build_event(name, payload)
      ActiveSupport::Notifications::Event.new("#{name}.solid_queue_listen_notify", Time.now, Time.now, "id", payload)
    end
end

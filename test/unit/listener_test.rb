# frozen_string_literal: true

require "test_helper"
require "test_helpers/listener_test_helper"
require "solid_queue/listen_notify/listener"

class ListenerTest < Minitest::Test
  include ListenNotifyTestDoubles
  include ListenNotifyTestWaiting

  LISTENER_CLASS = SolidQueue::ListenNotify::Listener

  def setup
    @listeners = []
  end

  def teardown
    # No rescue on purpose: #stop must never propagate whatever killed the
    # listener thread into the caller.
    @listeners.each(&:stop)
  end

  # Connection error resolution ------------------------------------------------

  def test_connection_errors_resolve_only_the_constants_that_exist
    errors = LISTENER_CLASS.connection_errors

    assert_includes errors, IOError
    assert_includes errors, EOFError
    assert_includes errors, Errno::EPIPE
    # pg and active_record are deliberately not loaded by the unit suite.
    refute defined?(::PG), "the unit tier must prove the listener loads without pg"
    assert errors.all? { |error| error.is_a?(Class) }
  end

  # Happy path -----------------------------------------------------------------

  def test_dispatches_the_payload_to_the_registry
    registry = FakeRegistry.new
    raw = FakeRawConnection.new([ [ :notify, "default" ] ])
    listener = build_listener(registry: registry, connection: FakeAdapterConnection.new(raw))

    listener.start
    raw.wait_until_idle

    assert_equal [ "default" ], registry.dispatched
  end

  def test_notify_event_carries_the_queue_name_and_the_dispatch_counts
    registry = FakeRegistry.new(dispatch_result: { woken: 2, skipped_saturated: 1 })
    raw = FakeRawConnection.new([ [ :notify, "alpha" ] ])
    listener = build_listener(registry: registry, connection: FakeAdapterConnection.new(raw))

    events = capture_listen_notify_events do |collected, mutex|
      listener.start
      raw.wait_until_idle
      wait_for(message: "no notify event") { mutex.synchronize { collected.any? { |e| e.name.start_with?("notify.") } } }
    end

    notify = events_named(events, "notify").first

    assert_equal "alpha", notify.payload[:queue_name]
    assert_equal 2, notify.payload[:woken]
    assert_equal 1, notify.payload[:skipped_saturated]
  end

  def test_sets_the_application_name_and_listens_on_the_configured_channel_in_order
    connection = FakeAdapterConnection.new
    listener = build_listener(connection: connection, channel: "my_channel", application_name: -> { "app-name" })

    listener.start
    connection.raw_connection.wait_until_idle

    assert_equal [ %(SET application_name = 'app-name'), %(LISTEN "my_channel") ], connection.executed
  end

  def test_start_event_reports_the_pid_and_channel
    connection = FakeAdapterConnection.new

    events = capture_listen_notify_events do |collected, mutex|
      listener = build_listener(connection: connection, channel: "chan")
      listener.start
      connection.raw_connection.wait_until_idle
      wait_for(message: "no start event") { mutex.synchronize { collected.any? { |e| e.name.start_with?("start_listener.") } } }
    end

    start = events_named(events, "start_listener").first

    assert_equal Process.pid, start.payload[:pid]
    assert_equal "chan", start.payload[:channel]
  end

  def test_start_is_idempotent
    listener = build_listener
    listener.start
    thread = listener.instance_variable_get(:@thread)
    listener.start

    assert listener.alive?
    assert_same thread, listener.instance_variable_get(:@thread), "start must not spawn a second thread"
  end

  # Keepalive ------------------------------------------------------------------

  def test_keepalive_does_not_fire_before_the_interval_elapses
    registry = FakeRegistry.new
    connection = FakeAdapterConnection.new
    clock = FakeClock.new(100)
    listener = build_listener(registry: registry, connection: connection, now: clock, keepalive_interval: 10)

    listener.start
    3.times { connection.raw_connection.wait_until_idle }

    assert_empty connection.raw_connection.async_exec_sql
    assert_equal 0, registry.sweeps
  end

  def test_keepalive_fires_once_the_clock_passes_the_interval
    registry = FakeRegistry.new
    connection = FakeAdapterConnection.new
    clock = FakeClock.new(100)
    listener = build_listener(registry: registry, connection: connection, now: clock, keepalive_interval: 10)

    listener.start
    connection.raw_connection.wait_until_idle
    clock.advance(11)

    wait_for(message: "keepalive never ran") { connection.raw_connection.async_exec_sql.any? }

    assert_equal [ "SELECT 1" ], connection.raw_connection.async_exec_sql
    wait_for(message: "workers never swept") { registry.sweeps == 1 }

    # The keepalive clock was reset, so it does not fire again on the next round.
    3.times { connection.raw_connection.wait_until_idle }

    assert_equal [ "SELECT 1" ], connection.raw_connection.async_exec_sql
  end

  # Reconnection ---------------------------------------------------------------

  def test_connection_error_disconnects_and_instruments_a_reconnect
    connection = FakeAdapterConnection.new(FakeRawConnection.new([ [ :raise, IOError ] ]))

    events = capture_listen_notify_events do |collected, mutex|
      listener = build_listener(connection: connection, channel: "chan", reconnect_wait: 0)
      listener.start
      wait_for(message: "no reconnect event") do
        mutex.synchronize { collected.any? { |e| e.name.start_with?("reconnect.") } }
      end
    end

    reconnect = events_named(events, "reconnect").first

    assert_equal "IOError", reconnect.payload[:error]
    assert_equal 1, reconnect.payload[:consecutive_failures]
    assert_equal false, reconnect.payload[:reported]
    assert connection.disconnected?, "the broken connection must be disconnected"
    refute connection.discarded?, "the graceful path must not discard"
    assert_includes connection.executed, %(UNLISTEN "chan")
  end

  # A database that is actually down fails at CONNECT, which is the case the
  # threshold exists for: the failures accumulate because nothing in between ever
  # succeeds.
  def test_error_reporter_is_only_called_once_the_threshold_is_exceeded
    reported = Queue.new
    provider = FailingProvider.new(3, FakeAdapterConnection.new)

    events = capture_listen_notify_events do |collected, mutex|
      listener = build_listener(connection_provider: provider, reconnect_wait: 0, reporting_threshold: 2,
                                error_reporter: ->(error) { reported << error })
      listener.start
      wait_for(message: "not enough reconnect events") do
        mutex.synchronize { collected.count { |e| e.name.start_with?("reconnect.") } >= 3 }
      end
    end

    reconnects = events_named(events, "reconnect")

    assert_equal [ 1, 2, 3 ], reconnects.first(3).map { |e| e.payload[:consecutive_failures] }
    assert_equal [ false, false, true ], reconnects.first(3).map { |e| e.payload[:reported] }
    assert_equal 1, reported.size
    assert_kind_of IOError, reported.pop
  end

  # A connection that flaps faster than keepalive_interval — connect, drop,
  # connect, drop — never reaches a notification or a keepalive to clear the
  # counter. Without a reset on connect it climbs past the threshold once and
  # then reports EVERY subsequent failure, forever, which is how an optional
  # optimization turns into a permanent alert storm.
  def test_a_successful_connect_clears_the_failure_count
    reported = Queue.new
    provider = FailingProvider.new(2, FakeAdapterConnection.new(FakeRawConnection.new([ [ :raise, IOError ] ])))

    events = capture_listen_notify_events do |collected, mutex|
      listener = build_listener(connection_provider: provider, reconnect_wait: 0, reporting_threshold: 2,
                                error_reporter: ->(error) { reported << error })
      listener.start
      wait_for(message: "not enough reconnect events") do
        mutex.synchronize { collected.count { |e| e.name.start_with?("reconnect.") } >= 3 }
      end
    end

    counts = events_named(events, "reconnect").first(3).map { |e| e.payload[:consecutive_failures] }

    assert_equal [ 1, 2, 1 ], counts,
      "two connect failures then a successful connect must put the counter back to zero"
    assert_empty drain(reported), "the threshold was never exceeded, so nothing may be reported"
  end

  def test_consecutive_failures_reset_after_a_successful_notification
    script = [ [ :raise, IOError ], [ :notify, "default" ], [ :raise, IOError ] ]
    connection = FakeAdapterConnection.new(FakeRawConnection.new(script))
    registry = FakeRegistry.new

    events = capture_listen_notify_events do |collected, mutex|
      listener = build_listener(registry: registry, connection: connection, reconnect_wait: 0)
      listener.start
      wait_for(message: "not enough reconnect events") do
        mutex.synchronize { collected.count { |e| e.name.start_with?("reconnect.") } >= 2 }
      end
    end

    assert_equal [ 1, 1 ], events_named(events, "reconnect").first(2).map { |e| e.payload[:consecutive_failures] }
    assert_equal [ "default" ], registry.dispatched
  end

  def test_reconnecting_acquires_a_fresh_connection_and_listens_again
    first = FakeAdapterConnection.new(FakeRawConnection.new([ [ :raise, EOFError ] ]))
    second = FakeAdapterConnection.new
    provider = FakeConnectionProvider.new(first, second)
    listener = build_listener(connection_provider: provider, channel: "chan", reconnect_wait: 0)

    listener.start
    second.raw_connection.wait_until_idle

    assert_equal 2, provider.calls
    assert_includes second.executed, %(LISTEN "chan")
  end

  # Shutdown -------------------------------------------------------------------

  def test_stop_terminates_promptly_and_instruments_a_shutdown
    connection = FakeAdapterConnection.new
    listener = build_listener(connection: connection, channel: "chan", wait_timeout: 0.05)

    events = capture_listen_notify_events do |collected, mutex|
      listener.start
      connection.raw_connection.wait_until_idle

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      listener.stop
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_operator elapsed, :<, (2 * 0.05) + 1, "stop must return within its join timeout"
      wait_for(message: "no shutdown event") do
        mutex.synchronize { collected.any? { |e| e.name.start_with?("shutdown.") } }
      end
    end

    refute listener.alive?
    assert connection.disconnected?, "the graceful path disconnects"
    assert_includes connection.executed, %(UNLISTEN "chan")
    assert_equal Process.pid, events_named(events, "shutdown").first.payload[:pid]
  end

  def test_stop_is_safe_on_a_listener_that_never_started
    listener = build_listener

    assert_silent { listener.stop }
    refute listener.alive?
  end

  # What a worker's shutdown hook does. It runs inside Solid Queue's five-second
  # budget, shared with everything else the worker has to do, so it must cost
  # nothing measurable — even when the listener thread is wedged in a call that
  # will not return for a minute.
  def test_a_non_joining_stop_returns_immediately_even_when_the_thread_is_wedged
    wedged = Class.new(FakeRawConnection) do
      def wait_for_notify(_timeout = nil)
        @idle_signals << :idle
        sleep 30
      end
    end.new

    connection = FakeAdapterConnection.new(wedged)
    listener = build_listener(connection: connection, wait_timeout: 1.0)
    listener.start
    wedged.wait_until_idle

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    listener.stop(join: false)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.05, "a non-joining stop took #{elapsed.round(3)}s"
    refute listener.alive?
    assert listener.stopping?
  end

  def test_a_non_joining_stop_still_lets_the_thread_close_its_own_connection
    connection = FakeAdapterConnection.new
    listener = build_listener(connection: connection, channel: "chan", wait_timeout: 0.01)
    listener.start
    connection.raw_connection.wait_until_idle

    listener.stop(join: false)

    wait_for(message: "the listener never closed its connection") { connection.disconnected? }
    assert_includes connection.executed, %(UNLISTEN "chan")
  end

  def test_discard_discards_the_connection_and_never_disconnects_it
    connection = FakeAdapterConnection.new
    listener = build_listener(connection: connection)

    listener.start
    connection.raw_connection.wait_until_idle
    listener.discard!

    assert connection.discarded?, "discard! must discard the adapter connection"
    refute connection.disconnected?, "discard! must never disconnect: the socket belongs to the parent"
    wait_for(message: "the listener loop never unwound") { !listener.alive? }
    refute connection.disconnected?, "the unwinding thread must not disconnect a discarded connection"
  end

  def test_stopping_from_inside_the_listener_thread_unwinds_without_joining_itself
    stopped = Queue.new
    connection = FakeAdapterConnection.new
    clock = FakeClock.new(0)
    registry = Object.new
    listener = build_listener(registry: registry, connection: connection, now: clock, keepalive_interval: 1)

    # This is what a keepalive sweep that reaps the last worker does: it stops
    # the listener from the listener's own thread.
    registry.define_singleton_method(:sweep_dead_workers) do
      listener.stop
      stopped << Thread.current
    end

    listener.start
    listener_thread = listener.instance_variable_get(:@thread)
    connection.raw_connection.wait_until_idle
    clock.advance(2)

    assert_same listener_thread, stopped.pop(timeout: 5), "the stop must have run on the listener thread"
    wait_for(message: "the listener never unwound") { !listener_thread.alive? }
    assert connection.disconnected?, "a self-stop still takes the graceful path"
  end

  # Fatal errors ---------------------------------------------------------------

  def test_a_non_connection_error_is_reported_and_kills_the_thread
    reported = Queue.new
    connection = FakeAdapterConnection.new(FakeRawConnection.new([ [ :raise, RuntimeError, "boom" ] ]))
    listener = build_listener(connection: connection, error_reporter: ->(error) { reported << error })

    events = silence_thread_errors do
      capture_listen_notify_events do |collected, mutex|
        listener.start
        wait_for(message: "the thread never died") { !listener.alive? }
        wait_for(message: "no shutdown event") do
          mutex.synchronize { collected.any? { |e| e.name.start_with?("shutdown.") } }
        end
      end
    end

    error = reported.pop

    assert_kind_of RuntimeError, error
    assert_equal "boom", error.message

    shutdown = events_named(events, "shutdown").first

    assert_equal "RuntimeError", shutdown.payload[:error]
    assert_equal "boom", shutdown.payload[:message]
  end

  def test_falls_back_to_solid_queues_thread_error_handler
    reported = Queue.new
    # Solid Queue itself is not loaded by the unit suite, which is exactly why
    # the listener has to check before reaching for it.
    refute SolidQueue.respond_to?(:on_thread_error)
    SolidQueue.stubs(:on_thread_error).returns(->(error) { reported << error })

    connection = FakeAdapterConnection.new(FakeRawConnection.new([ [ :raise, IOError ] ]))
    listener = build_listener(connection: connection, reconnect_wait: 0, reporting_threshold: 0)
    listener.start

    assert_kind_of IOError, reported.pop(timeout: 5)
  end

  def test_reporting_is_a_no_op_when_nothing_can_report
    connection = FakeAdapterConnection.new(FakeRawConnection.new([ [ :raise, IOError ] ]))
    listener = build_listener(connection: connection, reconnect_wait: 0, reporting_threshold: 0)

    listener.start
    connection.raw_connection.wait_until_idle

    assert listener.alive?, "an unreportable error must not take the listener down"
  end

  def test_a_connection_provider_that_cannot_connect_reports_and_stops
    reported = Queue.new
    provider = -> { raise NotImplementedError, "no provider configured" }
    listener = build_listener(connection_provider: provider, error_reporter: ->(error) { reported << error })

    silence_thread_errors do
      listener.start

      assert_kind_of NotImplementedError, reported.pop(timeout: 5)
      wait_for(message: "the thread never died") { !listener.alive? }

      # Joining a thread that died re-raises its exception: #stop must swallow it.
      assert_same listener, listener.stop
    end
  end

  # Instrumentation subscribers ------------------------------------------------
  #
  # An ActiveSupport::Notifications subscriber is arbitrary third-party code that
  # runs ON the listener thread. A bug in somebody's metrics block used to
  # propagate straight out of the run loop and kill the listener permanently —
  # for the lifetime of the process, with the workers left at a raised polling
  # interval and nothing to wake them.

  def test_a_subscriber_that_raises_on_every_notification_does_not_kill_the_listener
    registry = FakeRegistry.new
    raw = FakeRawConnection.new([ [ :notify, "alpha" ], [ :notify, "beta" ], [ :notify, "gamma" ] ])
    reported = Queue.new
    listener = build_listener(registry: registry, connection: FakeAdapterConnection.new(raw),
                              error_reporter: ->(error) { reported << error })

    with_raising_subscriber("notify.solid_queue_listen_notify") do
      listener.start
      raw.wait_until_idle
    end

    assert listener.alive?, "a subscriber's bug must not take the listener down"
    assert_equal %w[alpha beta gamma], registry.dispatched,
      "every notification must still have been fanned out"
    assert_equal 1, drain(reported).size, "the same broken subscriber must be reported once, not per event"
  end

  def test_a_subscriber_that_raises_on_the_keepalive_does_not_kill_the_listener
    registry = FakeRegistry.new
    connection = FakeAdapterConnection.new
    clock = FakeClock.new(100)
    listener = build_listener(registry: registry, connection: connection, now: clock, keepalive_interval: 10)

    with_raising_subscriber("keepalive.solid_queue_listen_notify") do
      listener.start
      connection.raw_connection.wait_until_idle
      clock.advance(11)
      wait_for(message: "keepalive never ran") { connection.raw_connection.async_exec_sql.any? }
    end

    assert listener.alive?
    wait_for(message: "workers never swept") { registry.sweeps >= 1 }
  end

  def test_a_subscriber_that_raises_on_the_start_event_does_not_kill_the_listener
    connection = FakeAdapterConnection.new
    listener = build_listener(connection: connection)

    with_raising_subscriber("start_listener.solid_queue_listen_notify") do
      listener.start
      connection.raw_connection.wait_until_idle
    end

    assert listener.alive?
  end

  # The other half of the same rule: an exception from the instrumented BLOCK is
  # ours, and a connection error inside a keepalive still has to reach the
  # reconnect path rather than being swallowed along with the subscriber bugs.
  def test_a_connection_error_inside_an_instrumented_block_still_reconnects
    connection = FakeAdapterConnection.new
    connection.raw_connection.stubs(:async_exec).raises(IOError, "server closed the connection")
    clock = FakeClock.new(100)

    events = capture_listen_notify_events do |collected, mutex|
      listener = build_listener(connection: connection, now: clock, keepalive_interval: 10, reconnect_wait: 0)
      listener.start
      connection.raw_connection.wait_until_idle
      clock.advance(11)
      wait_for(message: "no reconnect event") do
        mutex.synchronize { collected.any? { |e| e.name.start_with?("reconnect.") } }
      end
    end

    assert_equal "IOError", events_named(events, "reconnect").first.payload[:error]
  end

  # Fatal death ----------------------------------------------------------------

  def test_a_fatal_error_tells_the_registry_before_the_thread_dies
    registry = FakeRegistry.new
    connection = FakeAdapterConnection.new(FakeRawConnection.new([ [ :raise, RuntimeError, "boom" ] ]))
    listener = build_listener(registry: registry, connection: connection)

    silence_thread_errors do
      listener.start
      wait_for(message: "the thread never died") { !listener.alive? }
      wait_for(message: "the registry was never told") { registry.crashes.any? }
    end

    reported_listener, error = registry.crashes.first

    assert_same listener, reported_listener
    assert_kind_of RuntimeError, error
    assert_equal "boom", error.message
  end

  def test_a_registry_that_cannot_be_told_does_not_change_the_outcome
    registry = FakeRegistry.new
    registry.stubs(:listener_crashed).raises(NoMethodError, "API drift")
    connection = FakeAdapterConnection.new(FakeRawConnection.new([ [ :raise, RuntimeError, "boom" ] ]))
    reported = Queue.new
    listener = build_listener(registry: registry, connection: connection, error_reporter: ->(e) { reported << e })

    silence_thread_errors do
      listener.start
      assert_kind_of RuntimeError, reported.pop(timeout: 5)
      wait_for(message: "the thread never died") { !listener.alive? }
    end

    assert connection.disconnected?, "the connection must still be cleaned up"
  end

  # Raises a connection error for the first N checkouts, then hands out the
  # connection — a database that is down and then comes back.
  class FailingProvider
    def initialize(failures, connection)
      @remaining = failures
      @connection = connection
      @mutex = Mutex.new
    end

    def call
      @mutex.synchronize do
        if @remaining.positive?
          @remaining -= 1
          raise IOError, "connection refused"
        end
      end

      @connection
    end
  end

  private
    def drain(queue)
      Array.new(queue.size) { queue.pop }
    end

    # Subscribes a block that raises, the way an application's buggy metrics
    # subscriber would, and takes it away again afterwards.
    def with_raising_subscriber(name)
      subscriber = ActiveSupport::Notifications.subscribe(name) { |*| raise "subscriber bug" }
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def build_listener(registry: FakeRegistry.new, connection: nil, connection_provider: nil, **options)
      provider = connection_provider || FakeConnectionProvider.new(connection || FakeAdapterConnection.new)

      listener = LISTENER_CLASS.new(
        registry: registry,
        connection_provider: provider,
        channel: options.fetch(:channel, "solid_queue_ready"),
        wait_timeout: options.fetch(:wait_timeout, 0.01),
        keepalive_interval: options.fetch(:keepalive_interval, 10),
        reconnect_wait: options.fetch(:reconnect_wait, 0),
        reporting_threshold: options.fetch(:reporting_threshold, 6),
        application_name: options.fetch(:application_name, -> { "test-app" }),
        now: options.fetch(:now, -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }),
        error_reporter: options[:error_reporter]
      )

      @listeners << listener
      listener
    end
end

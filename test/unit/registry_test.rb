# frozen_string_literal: true

require "timeout"
require "test_helper"
require "test_helpers/listener_test_helper"
require "solid_queue/listen_notify/registry"

class RegistryTest < Minitest::Test
  include ListenNotifyTestDoubles
  include ListenNotifyTestWaiting

  REGISTRY_CLASS = SolidQueue::ListenNotify::Registry

  def setup
    REGISTRY_CLASS.reset!
    @listeners = []
    @listeners_mutex = Mutex.new
    @registry = REGISTRY_CLASS.new(listener_factory: listener_factory)
  end

  def teardown
    REGISTRY_CLASS.reset!
  end

  # Singleton ------------------------------------------------------------------

  def test_instance_is_memoized_and_reset_drops_it
    instance = REGISTRY_CLASS.instance

    assert_same instance, REGISTRY_CLASS.instance

    REGISTRY_CLASS.reset!

    refute_same instance, REGISTRY_CLASS.instance
  end

  def test_reset_stops_the_listener_it_owned
    @registry.register(FakeWorker.new)
    @registry.shutdown_for_reset!

    assert_equal 1, listener.stops
    assert_equal 0, listener.discards
    assert_empty @registry.workers
  end

  def test_the_default_listener_factory_uses_the_modules_connection_provider
    registry = REGISTRY_CLASS.new
    built = registry.send(:build_default_listener, registry)

    assert_kind_of SolidQueue::ListenNotify::Listener, built
    assert_same SolidQueue::ListenNotify.connection_provider, built.instance_variable_get(:@connection_provider)
  end

  def test_a_listener_built_without_any_connection_provider_says_so
    built = nil

    with_listen_notify_config(connection_provider: nil) do
      registry = REGISTRY_CLASS.new
      built = registry.send(:build_default_listener, registry)
    end

    assert_raises(NotImplementedError) { built.instance_variable_get(:@connection_provider).call }
  end

  # Registration ---------------------------------------------------------------

  def test_the_first_registration_starts_a_listener
    worker = FakeWorker.new

    @registry.register(worker)

    assert_equal [ worker ], @registry.workers
    assert_equal 1, @listeners.size
    assert_equal 1, listener.starts
    assert listener.alive?
  end

  def test_registering_the_same_worker_twice_counts_once_and_starts_one_listener
    worker = FakeWorker.new

    @registry.register(worker)
    @registry.register(worker)

    assert_equal [ worker ], @registry.workers
    assert_equal 1, @listeners.size
    assert_equal 1, listener.starts
  end

  def test_a_second_worker_does_not_start_a_second_listener
    @registry.register(FakeWorker.new)
    @registry.register(FakeWorker.new)

    assert_equal 2, @registry.workers.size
    assert_equal 1, @listeners.size
    assert_equal 1, listener.starts
  end

  def test_a_dead_listener_is_replaced_on_the_next_registration
    @registry.register(FakeWorker.new)
    listener.stop # simulates a listener thread that died on its own

    @registry.register(FakeWorker.new)

    assert_equal 2, @listeners.size
    assert_equal 1, @listeners.last.starts
  end

  def test_deregistering_the_last_worker_stops_the_listener
    worker = FakeWorker.new
    @registry.register(worker)
    @registry.deregister(worker)

    assert_empty @registry.workers
    assert_equal 1, listener.stops
    assert_nil @registry.listener
  end

  def test_deregistering_a_worker_that_is_not_the_last_keeps_the_listener
    first = FakeWorker.new
    second = FakeWorker.new
    @registry.register(first)
    @registry.register(second)
    @registry.deregister(first)

    assert_equal [ second ], @registry.workers
    assert_equal 0, listener.stops
  end

  def test_deregistering_an_unknown_worker_is_a_no_op
    worker = FakeWorker.new
    @registry.register(worker)
    @registry.deregister(FakeWorker.new)

    assert_equal [ worker ], @registry.workers
    assert_equal 0, listener.stops
  end

  # Dispatch -------------------------------------------------------------------

  def test_dispatch_wakes_only_the_workers_whose_queues_match
    alpha = FakeWorker.new(queues: [ "alpha" ])
    beta = FakeWorker.new(queues: [ "beta" ])
    wildcard = FakeWorker.new(queues: [ "*" ])
    [ alpha, beta, wildcard ].each { |worker| @registry.register(worker) }

    result = @registry.dispatch("alpha")

    assert_equal({ woken: 2, skipped_saturated: 0 }, result)
    assert_equal 1, alpha.wake_ups
    assert_equal 1, wildcard.wake_ups
    assert_equal 0, beta.wake_ups
  end

  def test_dispatch_matches_against_the_queues_captured_at_registration
    worker = FakeWorker.new(queues: [ "alpha*" ])
    @registry.register(worker)

    assert_equal({ woken: 1, skipped_saturated: 0 }, @registry.dispatch("alpha_urgent"))
    assert_equal({ woken: 0, skipped_saturated: 0 }, @registry.dispatch("beta"))
  end

  def test_saturated_workers_are_skipped_by_default
    saturated = FakeWorker.new(queues: [ "alpha" ], idle: false)
    idle = FakeWorker.new(queues: [ "alpha" ])
    [ saturated, idle ].each { |worker| @registry.register(worker) }

    result = @registry.dispatch("alpha")

    assert_equal({ woken: 1, skipped_saturated: 1 }, result)
    assert_equal 0, saturated.wake_ups
    assert_equal 1, idle.wake_ups
  end

  def test_saturated_workers_are_woken_when_configured_to
    saturated = FakeWorker.new(queues: [ "alpha" ], idle: false)
    @registry.register(saturated)

    with_listen_notify_config(wake_saturated_workers: true) do
      assert_equal({ woken: 1, skipped_saturated: 0 }, @registry.dispatch("alpha"))
    end

    assert_equal 1, saturated.wake_ups
  end

  def test_a_worker_with_a_broken_pool_is_woken_rather_than_skipped
    worker = FakeWorker.new(queues: [ "alpha" ])
    worker.pool.stubs(:idle?).raises(NoMethodError, "API drift")
    @registry.register(worker)

    assert_equal({ woken: 1, skipped_saturated: 0 }, @registry.dispatch("alpha"))
  end

  def test_a_worker_whose_wake_up_raises_is_reaped_without_disturbing_the_others
    broken = FakeWorker.new(queues: [ "alpha" ], wake_up_error: IOError)
    healthy = FakeWorker.new(queues: [ "alpha" ])
    [ broken, healthy ].each { |worker| @registry.register(worker) }

    result = @registry.dispatch("alpha")

    assert_equal({ woken: 1, skipped_saturated: 0 }, result)
    assert_equal [ healthy ], @registry.workers
    assert_equal 1, healthy.wake_ups
  end

  def test_reaping_the_last_worker_through_dispatch_stops_the_listener
    broken = FakeWorker.new(queues: [ "alpha" ], wake_up_error: Errno::EPIPE)
    @registry.register(broken)

    assert_equal({ woken: 0, skipped_saturated: 0 }, @registry.dispatch("alpha"))
    assert_empty @registry.workers
    assert_equal 1, listener.stops
  end

  def test_dispatch_on_an_empty_registry_returns_zero_counts
    assert_equal({ woken: 0, skipped_saturated: 0 }, @registry.dispatch("alpha"))
  end

  # Sweeping -------------------------------------------------------------------

  def test_dead_workers_are_swept_when_another_worker_registers
    dead = FakeWorker.new
    @registry.register(dead)
    dead.alive = false

    live = FakeWorker.new
    @registry.register(live)

    assert_equal [ live ], @registry.workers
  end

  def test_sweep_dead_workers_removes_them
    dead = FakeWorker.new
    live = FakeWorker.new
    [ dead, live ].each { |worker| @registry.register(worker) }
    dead.alive = false

    @registry.sweep_dead_workers

    assert_equal [ live ], @registry.workers
    assert_equal 0, listener.stops
  end

  def test_sweeping_to_empty_stops_the_listener
    worker = FakeWorker.new
    @registry.register(worker)
    worker.alive = false

    @registry.sweep_dead_workers

    assert_empty @registry.workers
    assert_equal 1, listener.stops
    assert_nil @registry.listener
  end

  def test_sweeping_an_already_empty_registry_is_a_no_op
    assert_silent { @registry.sweep_dead_workers }
    assert_empty @registry.workers
  end

  def test_a_worker_with_a_broken_alive_check_is_kept
    worker = FakeWorker.new
    @registry.register(worker)
    worker.stubs(:alive?).raises(NoMethodError, "API drift")

    @registry.sweep_dead_workers

    assert_equal [ worker ], @registry.workers
  end

  def test_a_worker_with_broken_queues_is_treated_as_a_wildcard
    worker = FakeWorker.new
    worker.stubs(:queues).raises(NoMethodError, "API drift")
    @registry.register(worker)

    assert_equal({ woken: 1, skipped_saturated: 0 }, @registry.dispatch("anything"))
  end

  # Fork guard -----------------------------------------------------------------

  def test_the_fork_guard_discards_the_listener_and_clears_the_workers
    @registry.register(FakeWorker.new)

    events = capture_listen_notify_events do
      in_a_forked_child { @registry.guard_fork! }
    end

    assert_equal 1, listener.discards
    assert_equal 0, listener.stops, "a forked child must never disconnect the parent's session"
    assert_empty @registry.workers
    assert_nil @registry.listener

    fork_detected = events_named(events, "fork_detected").first

    assert_equal Process.pid, fork_detected.payload[:parent_pid]
    assert_equal Process.pid + 1, fork_detected.payload[:pid]
  end

  def test_the_fork_guard_runs_at_most_once_per_fork
    @registry.register(FakeWorker.new)

    in_a_forked_child do
      @registry.guard_fork!
      @registry.guard_fork!
    end

    assert_equal 1, listener.discards
  end

  def test_registering_after_a_fork_starts_a_fresh_listener
    @registry.register(FakeWorker.new)
    worker = FakeWorker.new

    in_a_forked_child { @registry.register(worker) }

    assert_equal [ worker ], @registry.workers
    assert_equal 2, @listeners.size
    assert_equal 1, @listeners.first.discards
    assert_equal 1, @listeners.last.starts
  end

  def test_deregistering_after_a_fork_does_not_touch_the_parents_listener
    worker = FakeWorker.new
    @registry.register(worker)

    in_a_forked_child { @registry.deregister(worker) }

    assert_equal 1, listener.discards
    assert_equal 0, listener.stops
    assert_empty @registry.workers
  end

  def test_reset_after_a_fork_discards_instead_of_stopping
    @registry.register(FakeWorker.new)

    in_a_forked_child { @registry.shutdown_for_reset! }

    assert_equal 1, listener.discards
    assert_equal 0, listener.stops
  end

  # Wired to a real listener ---------------------------------------------------

  def test_a_real_listener_fans_a_notification_out_through_the_registry
    raw = FakeRawConnection.new([ [ :notify, "alpha" ] ])
    connection = FakeAdapterConnection.new(raw)
    registry = REGISTRY_CLASS.new(listener_factory: real_listener_factory(connection))

    alpha = FakeWorker.new(queues: [ "alpha" ])
    beta = FakeWorker.new(queues: [ "beta" ])
    [ alpha, beta ].each { |worker| registry.register(worker) }

    raw.wait_until_idle
    wait_for(message: "the worker was never woken") { alpha.wake_ups == 1 }

    assert_equal 0, beta.wake_ups
    assert_includes connection.executed, %(LISTEN "solid_queue_ready")
  ensure
    registry&.shutdown_for_reset!
  end

  def test_a_real_listener_stops_itself_when_the_registry_empties
    connection = FakeAdapterConnection.new
    registry = REGISTRY_CLASS.new(listener_factory: real_listener_factory(connection))
    worker = FakeWorker.new

    registry.register(worker)
    listener = registry.listener
    wait_for(message: "the listener never issued its LISTEN") { connection.executed.size == 2 }

    assert listener.alive?

    registry.deregister(worker)

    refute listener.alive?
    # Not joined, so the thread is still unwinding: what matters is that it does,
    # and that it closes its own connection on the way out.
    wait_for(message: "the listener never closed its connection") { connection.disconnected? }
  ensure
    registry&.shutdown_for_reset!
  end

  # A worker shutting down is on Solid Queue's clock: it gets five seconds for
  # everything, and a join here was spending up to three of them waiting for a
  # thread that unwinds on its own.
  def test_the_worker_shutdown_path_never_joins_the_listener_thread
    worker = FakeWorker.new
    @registry.register(worker)
    @registry.deregister(worker)

    assert_equal 1, listener.stops
    assert_equal 0, listener.joined_stops, "deregister must latch and return, not join"
  end

  def test_sweeping_to_empty_does_not_join_either
    worker = FakeWorker.new
    @registry.register(worker)
    worker.alive = false

    @registry.sweep_dead_workers

    assert_equal 1, listener.stops
    assert_equal 0, listener.joined_stops, "the sweep runs ON the listener thread"
  end

  def test_reset_still_joins_so_that_callers_get_a_clean_slate
    @registry.register(FakeWorker.new)
    @registry.shutdown_for_reset!

    assert_equal 1, listener.joined_stops
  end

  def test_deregistering_is_fast_even_with_a_listener_that_would_be_slow_to_join
    worker = FakeWorker.new
    @registry.register(worker)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @registry.deregister(worker)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.1, "deregister took #{elapsed.round(3)}s"
  end

  # Listener death -------------------------------------------------------------

  def test_a_crashed_listener_is_detached_so_that_a_later_register_revives_one
    @registry.register(FakeWorker.new)
    crashed = listener

    capture_listen_notify_log { @registry.listener_crashed(crashed, RuntimeError.new("boom")) }

    assert_nil @registry.listener, "the dead listener must not be left in place"

    @registry.register(FakeWorker.new)

    assert_equal 2, @listeners.size
    assert_equal 1, @listeners.last.starts
  end

  def test_a_crash_reported_by_a_listener_that_was_already_replaced_is_ignored
    @registry.register(FakeWorker.new)
    stale = listener
    stale.stop
    @registry.register(FakeWorker.new)
    current = @listeners.last

    capture_listen_notify_log { @registry.listener_crashed(stale, RuntimeError.new("boom")) }

    assert_same current, @registry.listener, "a stale crash report must not detach the live listener"
  end

  def test_a_crash_hands_the_still_registered_workers_to_the_module
    first = FakeWorker.new
    second = FakeWorker.new
    [ first, second ].each { |worker| @registry.register(worker) }
    reported = []
    SolidQueue::ListenNotify.stubs(:listener_crashed).with { |_error, workers| reported = workers; true }

    @registry.listener_crashed(listener, RuntimeError.new("boom"))

    assert_equal [ first, second ], reported
  end

  # Concurrency ----------------------------------------------------------------

  def test_concurrent_registration_and_deregistration_stays_consistent
    errors = Queue.new
    threads = 8
    iterations = 50

    Timeout.timeout(30) do
      Array.new(threads) do
        Thread.new do
          worker = FakeWorker.new(queues: [ "alpha" ])

          iterations.times do
            @registry.register(worker)
            @registry.dispatch("alpha")
            @registry.sweep_dead_workers
            @registry.deregister(worker)
          end
        rescue StandardError, Timeout::Error => e
          errors << e
        end
      end.each(&:join)
    end

    assert_empty drain(errors).map { |e| "#{e.class}: #{e.message}" }
    assert_empty @registry.workers
    assert_nil @registry.listener
    assert_operator @listeners.size, :>=, 1
    assert @listeners.all? { |built| built.starts == 1 }, "every listener must be started exactly once"
  end

  def test_concurrent_dispatch_never_sees_a_partially_registered_worker
    errors = Queue.new
    stop = false

    dispatcher = Thread.new do
      @registry.dispatch("alpha") until stop
    rescue StandardError => e
      errors << e
    end

    200.times do
      worker = FakeWorker.new(queues: [ "alpha" ])
      @registry.register(worker)
      @registry.deregister(worker)
    end

    stop = true
    dispatcher.join(10)

    assert_empty drain(errors).map { |e| "#{e.class}: #{e.message}" }
  end

  private
    def listener_factory
      lambda do |registry|
        FakeListener.new(registry).tap { |built| @listeners_mutex.synchronize { @listeners << built } }
      end
    end

    def real_listener_factory(connection)
      lambda do |registry|
        SolidQueue::ListenNotify::Listener.new(
          registry: registry,
          connection_provider: FakeConnectionProvider.new(connection),
          channel: "solid_queue_ready",
          wait_timeout: 0.01,
          keepalive_interval: 10,
          reconnect_wait: 0,
          application_name: -> { "test-app" }
        )
      end
    end

    # The listener built most recently; every test but the fork ones has exactly
    # one.
    def listener
      @listeners.first
    end

    # Runs the block as if the process had forked: the pid changes underneath a
    # registry that still holds the parent's listener. Actually forking would
    # leave the assertions in the child.
    def in_a_forked_child(&block)
      child_pid = Process.pid + 1
      Process.stubs(:pid).returns(child_pid)
      block.call
    ensure
      Process.unstub(:pid)
    end

    def drain(queue)
      Array.new(queue.size) { queue.pop }
    end
end

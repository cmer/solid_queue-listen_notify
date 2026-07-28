# frozen_string_literal: true

require "test_helper"
require "test_helpers/listener_test_helper"
require "active_support/ordered_options"

# The lifecycle hooks Solid Queue calls, and the polling override they apply.
# Every test here also asserts the thing that makes this safe to install: a
# non-operational setup leaves the worker exactly as it found it.
class RegisterTest < Minitest::Test
  include ListenNotifyTestWaiting

  LN = SolidQueue::ListenNotify
  REGISTRY_CLASS = SolidQueue::ListenNotify::Registry
  PREFLIGHT_CLASS = SolidQueue::ListenNotify::Preflight

  # Only what the module touches: Solid Queue's Worker inherits polling_interval
  # from Processes::Poller, which exposes it as an accessor.
  FakeWorker = Struct.new(:polling_interval, :name)

  class WakeableWorker < FakeWorker
    def wake_ups = @wake_ups ||= 0
    def wake_up = @wake_ups = wake_ups + 1
  end

  class InstantPreflight
    def run = PREFLIGHT_CLASS::Result.new(operational: false, reason: :test)
  end

  class ForgetfulProvider
    attr_reader :forgets

    def initialize
      @forgets = 0
    end

    def call = :connection
    def forget_pools! = @forgets += 1
  end

  class FakeRegistry
    attr_reader :registered, :deregistered

    def initialize
      @registered = []
      @deregistered = []
    end

    def register(worker)
      @registered << worker
      self
    end

    def deregister(worker)
      @deregistered << worker
      self
    end
  end

  def setup
    LN.reset!
    REGISTRY_CLASS.reset!
  end

  def teardown
    LN.reset!
    REGISTRY_CLASS.reset!
  end

  # Not operational ------------------------------------------------------------

  def test_a_worker_is_left_completely_alone_when_the_gem_is_not_operational
    LN.stubs(:operational?).returns(false)
    worker = FakeWorker.new(0.1, "worker-1")

    assert_nil LN.register(worker)

    assert_in_delta 0.1, worker.polling_interval
    refute REGISTRY_CLASS.instantiated?, "a non-operational gem must not build a registry"
  end

  def test_deregister_does_not_build_a_registry_that_never_existed
    assert_nil LN.deregister(FakeWorker.new(0.1, "worker-1"))

    refute REGISTRY_CLASS.instantiated?
  end

  def test_deregister_reaches_a_registry_that_does_exist
    registry = FakeRegistry.new
    REGISTRY_CLASS.stubs(:instantiated?).returns(true)
    REGISTRY_CLASS.stubs(:instance).returns(registry)
    worker = FakeWorker.new(0.1, "worker-1")

    LN.deregister(worker)

    assert_equal [ worker ], registry.deregistered
  end

  # Operational ----------------------------------------------------------------

  def test_registering_raises_the_polling_interval_and_registers_the_worker
    registry = stub_operational_registry
    worker = FakeWorker.new(0.1, "worker-1")

    events = capture_listen_notify_events { LN.register(worker) }

    assert_in_delta 10.0, worker.polling_interval
    assert_equal [ worker ], registry.registered

    override = events_named(events, "override_polling_interval").first

    assert_equal "worker-1", override.payload[:worker_name]
    assert_in_delta 0.1, override.payload[:from]
    assert_in_delta 10.0, override.payload[:to]
  end

  def test_a_worker_that_already_polls_less_often_is_never_slowed_down
    registry = stub_operational_registry
    worker = FakeWorker.new(30, "worker-1")

    events = capture_listen_notify_events { LN.register(worker) }

    assert_equal 30, worker.polling_interval
    assert_empty events_named(events, "override_polling_interval")
    assert_equal [ worker ], registry.registered
  end

  def test_a_nil_fallback_polling_interval_never_touches_the_worker
    registry = stub_operational_registry
    worker = FakeWorker.new(0.1, "worker-1")

    with_listen_notify_config(fallback_polling_interval: nil) do
      LN.register(worker)
    end

    assert_in_delta 0.1, worker.polling_interval
    assert_equal [ worker ], registry.registered
  end

  def test_a_worker_without_a_polling_interval_is_registered_anyway
    registry = stub_operational_registry
    worker = Object.new

    assert_silent { LN.register(worker) }

    assert_equal [ worker ], registry.registered
  end

  def test_a_worker_without_a_name_still_gets_an_override_event
    registry = stub_operational_registry
    worker = Struct.new(:polling_interval).new(0.1)

    events = capture_listen_notify_events { LN.register(worker) }

    assert_nil events_named(events, "override_polling_interval").first.payload[:worker_name]
    assert_equal [ worker ], registry.registered
  end

  # Failure containment ---------------------------------------------------------

  def test_a_registry_that_blows_up_degrades_instead_of_raising
    LN.stubs(:operational?).returns(true)
    REGISTRY_CLASS.stubs(:instance).raises(NoMethodError, "API drift")
    worker = FakeWorker.new(0.1, "worker-1")
    result = nil

    log = capture_listen_notify_log { result = LN.register(worker) }

    assert_nil result
    assert_includes log, "could not register a worker"
    assert_includes log, "API drift"
    assert_in_delta 0.1, worker.polling_interval, 0.001,
      "a worker that could not be registered must not be left polling slowly with nothing to wake it"
  end

  def test_a_deregister_that_blows_up_degrades_instead_of_raising
    REGISTRY_CLASS.stubs(:instantiated?).returns(true)
    REGISTRY_CLASS.stubs(:instance).raises(NoMethodError, "API drift")
    result = nil

    log = capture_listen_notify_log { result = LN.deregister(FakeWorker.new(0.1, "worker-1")) }

    assert_nil result
    assert_includes log, "could not deregister a worker"
  end

  def test_a_preflight_that_blows_up_degrades_instead_of_raising
    LN.stubs(:operational?).raises(NotImplementedError, "no provider")
    result = nil

    log = capture_listen_notify_log { result = LN.register(FakeWorker.new(0.1, "worker-1")) }

    assert_nil result
    assert_includes log, "could not register a worker"
    refute REGISTRY_CLASS.instantiated?
  end

  # Listener death ---------------------------------------------------------------
  #
  # The gem raises polling intervals on the strength of a promise: notifications
  # arrive. When the listener dies for good that promise is broken, and a worker
  # left polling every 10 seconds with nothing to wake it is strictly worse than
  # never having installed the gem — so the promise has to be withdrawn.

  def test_a_listener_death_puts_every_raised_interval_back
    stub_operational_registry
    first = FakeWorker.new(0.1, "worker-1")
    second = FakeWorker.new(0.5, "worker-2")
    [ first, second ].each { |worker| LN.register(worker) }

    assert_in_delta 10.0, first.polling_interval
    assert_in_delta 10.0, second.polling_interval

    capture_listen_notify_log { LN.listener_crashed(RuntimeError.new("boom"), [ first, second ]) }

    assert_in_delta 0.1, first.polling_interval
    assert_in_delta 0.5, second.polling_interval
  end

  def test_a_listener_death_wakes_the_workers_it_restored
    stub_operational_registry
    worker = WakeableWorker.new(0.1, "worker-1")
    LN.register(worker)

    capture_listen_notify_log { LN.listener_crashed(RuntimeError.new("boom"), [ worker ]) }

    assert_equal 1, worker.wake_ups,
      "a sleeping worker has to be woken to re-read the interval, not left to finish its 10s sleep"
  end

  def test_a_listener_death_instruments_the_restore_and_says_so_loudly
    stub_operational_registry
    worker = FakeWorker.new(0.1, "worker-1")
    LN.register(worker)

    log = nil
    events = capture_listen_notify_events do
      log = capture_listen_notify_log { LN.listener_crashed(RuntimeError.new("boom"), [ worker ]) }
    end

    restore = events_named(events, "override_polling_interval").last

    assert_equal true, restore.payload[:restored]
    assert_equal "worker-1", restore.payload[:worker_name]
    assert_in_delta 10.0, restore.payload[:from]
    assert_in_delta 0.1, restore.payload[:to]

    assert_includes log, "ERROR"
    assert_includes log, "listener died permanently"
    assert_includes log, "RuntimeError: boom"
    assert_includes log, "1 worker(s) restored"
  end

  def test_a_worker_whose_interval_was_never_raised_is_left_alone
    stub_operational_registry
    worker = FakeWorker.new(30, "worker-1")
    LN.register(worker)

    events = capture_listen_notify_events do
      capture_listen_notify_log { LN.listener_crashed(RuntimeError.new("boom"), [ worker ]) }
    end

    assert_equal 30, worker.polling_interval
    assert_empty events_named(events, "override_polling_interval")
  end

  def test_a_deregistered_worker_is_no_longer_restored_on_a_later_death
    registry = stub_operational_registry
    REGISTRY_CLASS.stubs(:instantiated?).returns(true)
    worker = FakeWorker.new(0.1, "worker-1")
    LN.register(worker)
    worker.polling_interval = 7 # whatever the application did with it afterwards
    LN.deregister(worker)

    capture_listen_notify_log { LN.listener_crashed(RuntimeError.new("boom"), [ worker ]) }

    assert_equal 7, worker.polling_interval
    assert_equal [ worker ], registry.deregistered
  end

  def test_a_worker_that_cannot_be_restored_does_not_stop_the_others
    stub_operational_registry
    broken = FakeWorker.new(0.1, "broken")
    healthy = FakeWorker.new(0.1, "healthy")
    [ broken, healthy ].each { |worker| LN.register(worker) }
    broken.stubs(:polling_interval=).raises(NoMethodError, "API drift")

    capture_listen_notify_log { LN.listener_crashed(RuntimeError.new("boom"), [ broken, healthy ]) }

    assert_in_delta 0.1, healthy.polling_interval
  end

  # Fork hook -------------------------------------------------------------------

  def test_after_fork_does_nothing_when_no_registry_exists
    assert_silent { LN.after_fork }

    refute REGISTRY_CLASS.instantiated?
  end

  def test_after_fork_guards_the_registry_that_exists
    registry = REGISTRY_CLASS.instance
    registry.expects(:guard_fork!).once

    LN.after_fork
  end

  # fork() copies only the calling thread, so every mutex another thread held at
  # fork time is inherited LOCKED with nobody left to unlock it. The widest
  # window belongs to the preflight lock: operational? holds it across connecting
  # to Postgres and a self-test that waits up to two seconds. A child that forked
  # in that window used to hang the first worker that registered — permanently,
  # and inside a lifecycle hook.

  def test_after_fork_replaces_a_preflight_lock_that_was_inherited_locked
    LN.reset!
    PREFLIGHT_CLASS.stubs(:new).returns(InstantPreflight.new)

    inherited = LN.class_variable_get(:@@preflight_lock)
    holder = Thread.new { inherited.lock; sleep }
    wait_for(message: "the lock was never taken") { inherited.locked? }

    LN.after_fork

    refute_same inherited, LN.class_variable_get(:@@preflight_lock),
      "the inherited lock is held forever: it has to be replaced, not waited on"

    completed = Thread.new { LN.operational? }

    assert completed.join(5), "operational? deadlocked on the lock inherited from the fork"
  ensure
    holder&.kill
    completed&.kill
  end

  def test_after_fork_replaces_the_registrys_creation_lock
    inherited = REGISTRY_CLASS.creation_lock
    holder = Thread.new { inherited.lock; sleep }
    wait_for(message: "the lock was never taken") { inherited.locked? }

    LN.after_fork

    refute_same inherited, REGISTRY_CLASS.creation_lock

    built = Thread.new { REGISTRY_CLASS.instance }

    assert built.join(5), "Registry.instance deadlocked on the creation lock inherited from the fork"
  ensure
    holder&.kill
    built&.kill
  end

  def test_after_fork_makes_the_connection_provider_forget_its_pools
    provider = ForgetfulProvider.new

    with_listen_notify_config(connection_provider: provider) do
      LN.after_fork
    end

    assert_equal 1, provider.forgets,
      "ActiveRecord discards those pools behind our back, so a memoized one is dead in the child"
  end

  def test_after_fork_tolerates_a_connection_provider_that_is_just_a_proc
    with_listen_notify_config(connection_provider: -> { :connection }) do
      assert_silent { LN.after_fork }
    end
  end

  # Configuration copy (what the Railtie initializer does) -----------------------

  def test_apply_configuration_copies_only_the_options_that_were_set
    options = ActiveSupport::OrderedOptions.new
    options.channel = "other_channel"
    options.auto_install_trigger = false

    previous_fallback = LN.fallback_polling_interval

    with_listen_notify_config(channel: LN.channel, auto_install_trigger: LN.auto_install_trigger) do
      LN.apply_configuration(options)

      assert_equal "other_channel", LN.channel
      # false is not the default, so this proves the copy actually happened.
      assert_equal false, LN.auto_install_trigger
      assert_equal previous_fallback, LN.fallback_polling_interval
    end
  end

  def test_apply_configuration_warns_about_an_unknown_option
    options = ActiveSupport::OrderedOptions.new
    options.chanel = "typo"

    log = capture_listen_notify_log { LN.apply_configuration(options) }

    assert_includes log, "ignoring unknown configuration option :chanel"
    assert_equal "solid_queue_ready", LN.channel
  end

  def test_apply_configuration_accepts_no_configuration_at_all
    assert_nil LN.apply_configuration(nil)
    assert_nil LN.apply_configuration(ActiveSupport::OrderedOptions.new)
  end

  private
    def stub_operational_registry
      LN.stubs(:operational?).returns(true)
      FakeRegistry.new.tap do |registry|
        REGISTRY_CLASS.stubs(:instance).returns(registry)
      end
    end
end

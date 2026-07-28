# frozen_string_literal: true

require "timeout"
require "test_helper"
require "solid_queue/listen_notify/connection_provider"

# The provider is the one place that reaches into ActiveRecord's pools, so what
# is unit-testable here is the bookkeeping AROUND that: which pool it memoizes,
# and — the part that was silently broken — what becomes of that memo after a
# fork.
class ConnectionProviderTest < Minitest::Test
  PROVIDER_CLASS = SolidQueue::ListenNotify::ConnectionProvider

  # Enough of an ActiveRecord::ConnectionAdapters::ConnectionPool for the
  # provider, plus a `discard!` standing in for what `PoolConfig.discard_pools!`
  # does to it behind our back in a forked child.
  class FakePool
    attr_reader :removals, :disconnects

    def initialize
      @checkouts = 0
      @removals = []
      @disconnects = 0
      @discarded = false
    end

    def discard!
      @discarded = true
    end

    def checkout
      raise NoMethodError, "undefined method 'lease' for nil" if @discarded

      @checkouts += 1
      "connection-#{@checkouts}"
    end

    def remove(connection)
      @removals << connection
    end

    def disconnect!
      @disconnects += 1
    end
  end

  attr_reader :pools

  def setup
    @provider = PROVIDER_CLASS.new
    @pools = []

    # The only part of the provider that needs a real ActiveRecord.
    pools = @pools
    @provider.define_singleton_method(:establish_isolated_pool) do |_name|
      FakePool.new.tap { |pool| pools << pool }
    end
  end

  def with_listen_database(name = "listen", &block)
    with_listen_notify_config(listen_database: name, &block)
  end

  # Memoization ----------------------------------------------------------------

  def test_an_isolated_pool_is_built_once_and_reused
    with_listen_database do
      assert_equal "connection-1", @provider.call
      assert_equal "connection-2", @provider.call
    end

    assert_equal 1, pools.size, "the pool must be memoized, not rebuilt per connection"
    assert_equal [ "connection-1", "connection-2" ], pools.first.removals,
      "every connection handed out has to be removed from its pool"
  end

  def test_reset_drops_the_memo_and_disconnects_what_it_dropped
    with_listen_database do
      @provider.call
      @provider.reset!
      @provider.call
    end

    assert_equal 2, pools.size
    assert_equal 1, pools.first.disconnects
  end

  # Fork -----------------------------------------------------------------------
  #
  # ActiveRecord's own ForkTracker hook calls PoolConfig.discard_pools!, which
  # discards every pool it knows about — including the one behind our private
  # handler, which it knows about because establish_connection registered it.
  # What we keep is then a reference to a pool whose innards have been thrown
  # away, and the first checkout in the child raises. Without the fix, the gem
  # was silently inactive in EVERY forked child of a process that used
  # `listen_database`.

  def test_a_pool_active_record_discarded_is_unusable
    pool = FakePool.new
    pool.checkout
    pool.discard!

    assert_raises(NoMethodError, "if this stops raising, the fork tests below are vacuous") { pool.checkout }
  end

  def test_forget_pools_makes_the_next_call_build_a_fresh_pool
    with_listen_database do
      @provider.call
      pools.first.discard! # what ActiveRecord does to it in the child

      @provider.forget_pools!

      assert_equal "connection-1", @provider.call
    end

    assert_equal 2, pools.size
  end

  def test_forget_pools_never_touches_the_connections_the_parent_still_owns
    with_listen_database do
      @provider.call
      @provider.forget_pools!
    end

    assert_equal 0, pools.first.disconnects,
      "those sockets belong to the parent: disconnecting one would kill its listener"
  end

  # fork() copies only the calling thread, so a mutex another thread held at fork
  # time stays locked forever in the child.
  def test_forget_pools_replaces_a_mutex_that_was_inherited_locked
    inherited = @provider.instance_variable_get(:@mutex)
    holder = Thread.new { inherited.lock; sleep }
    Timeout.timeout(5) { sleep 0.001 until inherited.locked? }

    @provider.forget_pools!

    refute_same inherited, @provider.instance_variable_get(:@mutex)

    called = Thread.new { with_listen_database { @provider.call } }

    assert called.join(5), "the provider deadlocked on the mutex inherited from the fork"
  ensure
    holder&.kill
    called&.kill
  end

  # Belt and braces behind forget_pools!, for a child that somehow never ran the
  # fork hook at all.
  def test_the_memo_is_keyed_by_pid
    child_pid = ::Process.pid + 1

    with_listen_database do
      @provider.call

      ::Process.stubs(:pid).returns(child_pid)

      @provider.call
    end

    assert_equal 2, pools.size, "a child must not reach into a pool memoized by its parent"
  ensure
    ::Process.unstub(:pid)
  end

  def test_two_listen_databases_get_a_pool_each
    with_listen_database("one") { @provider.call }
    with_listen_database("two") { @provider.call }

    assert_equal 2, pools.size
  end
end

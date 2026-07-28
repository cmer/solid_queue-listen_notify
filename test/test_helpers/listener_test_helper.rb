# frozen_string_literal: true

require "stringio"
require "active_support/notifications"

# Test doubles for the listener/registry unit tier. Nothing here touches pg,
# ActiveRecord or Solid Queue: the unit suite doubles as proof that the
# concurrency core loads and runs without any of them.
module ListenNotifyTestDoubles
  # Scriptable stand-in for PG::Connection. Each entry of the script is consumed
  # by one wait_for_notify call:
  #
  #   [ :notify, "queue_name" ]   => yields (channel, backend_pid, payload)
  #   [ :sleep ]                  => returns nil (one idle round)
  #   [ :raise, SomeError ]       => raises
  #
  # Once the script is exhausted every round pushes onto #idle_signals, so tests
  # can wait for the loop to have caught up instead of sleeping.
  class FakeRawConnection
    DEFAULT_CHANNEL = "solid_queue_ready"
    DEFAULT_BACKEND_PID = 123

    class FakeResult
      attr_reader :clears

      def initialize
        @clears = 0
      end

      def clear
        @clears += 1
      end
    end

    attr_reader :idle_signals

    def initialize(script = [])
      @script = script.dup
      @mutex = Mutex.new
      @async_exec_sql = []
      @waits = 0
      @idle_signals = Queue.new
    end

    def wait_for_notify(timeout = nil)
      operation = @mutex.synchronize do
        @waits += 1
        @script.shift
      end

      case operation && operation.first
      when :notify
        payload = operation[1]
        yield(DEFAULT_CHANNEL, DEFAULT_BACKEND_PID, payload.to_s) if block_given?
        DEFAULT_CHANNEL
      when :raise
        raise operation[1], (operation[2] || "scripted connection failure")
      when :sleep
        sleep(operation[1] || 0)
        nil
      else
        @idle_signals << :idle
        sleep(timeout || 0.01)
        nil
      end
    end

    def async_exec(sql)
      @mutex.synchronize { @async_exec_sql << sql }
      FakeResult.new
    end

    def async_exec_sql
      @mutex.synchronize { @async_exec_sql.dup }
    end

    def waits
      @mutex.synchronize { @waits }
    end

    # Blocks until the loop has run out of scripted operations at least once.
    def wait_until_idle(timeout: 5)
      raise "listener loop never went idle within #{timeout}s" unless @idle_signals.pop(timeout: timeout)
      true
    end
  end

  # Stand-in for an ActiveRecord PostgreSQL adapter connection.
  class FakeAdapterConnection
    attr_reader :raw_connection

    def initialize(raw_connection = FakeRawConnection.new)
      @raw_connection = raw_connection
      @mutex = Mutex.new
      @executed = []
      @disconnects = 0
      @discards = 0
    end

    def execute(sql, _name = nil)
      @mutex.synchronize { @executed << sql }
      nil
    end

    def quote(value)
      "'#{value}'"
    end

    def quote_column_name(name)
      "\"#{name}\""
    end

    def disconnect!
      @mutex.synchronize { @disconnects += 1 }
    end

    def discard!
      @mutex.synchronize { @discards += 1 }
    end

    def executed
      @mutex.synchronize { @executed.dup }
    end

    def disconnects
      @mutex.synchronize { @disconnects }
    end

    def discards
      @mutex.synchronize { @discards }
    end

    def disconnected?
      disconnects.positive?
    end

    def discarded?
      discards.positive?
    end
  end

  # Hands out connections in order, repeating the last one for every subsequent
  # reconnect, so a single script can span reconnects.
  class FakeConnectionProvider
    def initialize(*connections)
      @connections = connections.flatten
      @mutex = Mutex.new
      @calls = 0
    end

    def call
      @mutex.synchronize do
        connection = @connections[@calls] || @connections.last
        @calls += 1
        connection
      end
    end

    def calls
      @mutex.synchronize { @calls }
    end
  end

  # Monotonic clock the test drives by hand.
  class FakeClock
    def initialize(value = 0.0)
      @value = value.to_f
      @mutex = Mutex.new
    end

    def call
      @mutex.synchronize { @value }
    end

    def advance(seconds)
      @mutex.synchronize { @value += seconds.to_f }
    end
  end

  class FakeRegistry
    attr_reader :dispatch_result

    def initialize(dispatch_result: { woken: 0, skipped_saturated: 0 })
      @dispatch_result = dispatch_result
      @mutex = Mutex.new
      @dispatched = []
      @sweeps = 0
      @crashes = []
    end

    def dispatch(queue_name)
      @mutex.synchronize { @dispatched << queue_name }
      dispatch_result
    end

    def sweep_dead_workers
      @mutex.synchronize { @sweeps += 1 }
    end

    def listener_crashed(listener, error = nil)
      @mutex.synchronize { @crashes << [ listener, error ] }
      self
    end

    def dispatched
      @mutex.synchronize { @dispatched.dup }
    end

    def sweeps
      @mutex.synchronize { @sweeps }
    end

    def crashes
      @mutex.synchronize { @crashes.dup }
    end
  end

  class FakeWorker
    class FakePool
      def initialize(idle)
        @idle = idle
      end

      attr_writer :idle

      def idle?
        @idle
      end
    end

    attr_reader :queues, :pool, :name

    def initialize(queues: [ "*" ], alive: true, idle: true, wake_up_error: nil, name: nil)
      @queues = queues
      @pool = FakePool.new(idle)
      @alive = alive
      @wake_up_error = wake_up_error
      @name = name
      @mutex = Mutex.new
      @wake_ups = 0
    end

    def wake_up
      @mutex.synchronize { @wake_ups += 1 }
      raise @wake_up_error if @wake_up_error
    end

    def alive?
      @alive
    end

    def alive=(value)
      @alive = value
    end

    def wake_ups
      @mutex.synchronize { @wake_ups }
    end
  end

  class FakeListener
    attr_reader :registry

    def initialize(registry = nil)
      @registry = registry
      @mutex = Mutex.new
      @starts = 0
      @stops = 0
      @joined_stops = 0
      @discards = 0
      @alive = false
    end

    def start
      @mutex.synchronize do
        @starts += 1
        @alive = true
      end
      self
    end

    def stop(join: true)
      @mutex.synchronize do
        @stops += 1
        @joined_stops += 1 if join
        @alive = false
      end
      self
    end

    def discard!
      @mutex.synchronize do
        @discards += 1
        @alive = false
      end
      self
    end

    def alive?
      @mutex.synchronize { @alive }
    end

    def starts
      @mutex.synchronize { @starts }
    end

    def stops
      @mutex.synchronize { @stops }
    end

    # Stops that asked to be joined. The worker shutdown path must never be one
    # of them: it runs inside Solid Queue's 5-second shutdown budget.
    def joined_stops
      @mutex.synchronize { @joined_stops }
    end

    def discards
      @mutex.synchronize { @discards }
    end
  end
end

module ListenNotifyTestWaiting
  # Polls instead of sleeping a fixed amount: the assertion decides when we are
  # done, not the clock.
  def wait_for(timeout: 5, message: "condition never became true")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return true if yield

      sleep 0.005
    end

    flunk("#{message} (waited #{timeout}s)")
  end

  CapturedEvent = Struct.new(:name, :payload)

  # Collects every *.solid_queue_listen_notify event fired inside the block. The
  # five-argument block form is used on purpose: it is the one shape every
  # ActiveSupport version dispatches identically.
  def capture_listen_notify_events
    mutex = Mutex.new
    events = []

    subscriber = ActiveSupport::Notifications.subscribe(/\.solid_queue_listen_notify\z/) do |name, _started, _finished, _id, payload|
      mutex.synchronize { events << CapturedEvent.new(name, payload) }
    end

    begin
      yield events, mutex
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    mutex.synchronize { events.dup }
  end

  def events_named(events, name)
    events.select { |event| event.name == "#{name}.solid_queue_listen_notify" }
  end

  def silence_thread_errors
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end
end

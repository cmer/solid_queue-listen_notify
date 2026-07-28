# frozen_string_literal: true

module SolidQueue
  module ListenNotify
    # One background thread owning one dedicated Postgres connection: LISTENs on
    # the configured channel and hands every notification to the registry, which
    # fans it out to the workers running in this process.
    #
    # Everything the listener talks to is injected, so the whole state machine
    # (reconnects, keepalive, shutdown) is unit-testable without a database.
    class Listener
      # Resolved by name, on demand, rather than captured in a constant at load
      # time: this file must load when neither pg nor active_record is loaded
      # yet (Bundler requires the gem long before ActiveRecord requires the
      # PostgreSQL adapter), and a rescue list captured too early would silently
      # stop matching PG::Error.
      CONNECTION_ERROR_NAMES = %w[
        PG::Error
        ActiveRecord::ConnectionNotEstablished
        ActiveRecord::ConnectionFailed
        ActiveRecord::StatementInvalid
        IOError
        EOFError
        Errno::EPIPE
        Errno::ECONNRESET
      ].freeze

      def self.connection_errors
        CONNECTION_ERROR_NAMES.filter_map do |name|
          Object.const_get(name) if Object.const_defined?(name)
        end
      end

      THREAD_NAME = "solid_queue-listen_notify"

      attr_reader :channel

      def initialize(registry:, connection_provider:,
                     channel: ListenNotify.channel,
                     wait_timeout: ListenNotify.wait_timeout,
                     keepalive_interval: ListenNotify.keepalive_interval,
                     reconnect_wait: ListenNotify.reconnect_wait,
                     reporting_threshold: ListenNotify.connection_errors_reporting_threshold,
                     application_name: -> { ListenNotify.application_name },
                     now: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) },
                     error_reporter: nil)
        @registry = registry
        @connection_provider = connection_provider
        @channel = channel.to_s
        @wait_timeout = wait_timeout.to_f
        @keepalive_interval = keepalive_interval.to_f
        @reconnect_wait = reconnect_wait.to_f
        @reporting_threshold = reporting_threshold.to_i
        @application_name = application_name
        @now = now
        @error_reporter = error_reporter

        # Written by whoever calls #stop/#discard!, read by the listener thread.
        # A plain ivar is enough: it is a latch that only ever goes false -> true
        # and a stale read merely costs one more wait_for_notify round. Using a
        # lock here would buy nothing and could block the stopping thread.
        @stopping = false
        @discarded = false
        @consecutive_failures = 0
        # Exception classes an instrumentation subscriber has already been
        # reported for. Only ever touched from the listener thread.
        @reported_subscriber_errors = {}
      end

      # Idempotent: a listener that is already running is left alone.
      def start
        return self if alive?

        @stopping = false
        @discarded = false
        @started_pid = ::Process.pid
        @thread = Thread.new { run }
        @thread.name = THREAD_NAME
        self
      end

      # `join: false` is the shutdown path a WORKER takes: it latches and
      # returns in microseconds, leaving the loop to notice within one
      # `wait_timeout` and close its own connection on the way out. Solid Queue
      # gives a worker five seconds to shut down in total, and a listener join
      # was spending up to three of them on a thread that needed no help.
      #
      # `join: true` (the default) is for tests and for anything that needs the
      # connection provably gone before it continues.
      def stop(join: true)
        @stopping = true
        thread = @thread
        @thread = nil
        return self if thread.nil?
        return self unless join

        # Stopping from inside the listener thread itself (the registry sweeps
        # its last worker on the keepalive tick) must not join: the latch above
        # already unwinds the run loop, and Thread#join on the current thread
        # raises.
        return self if thread == Thread.current

        joined =
          begin
            thread.join(join_timeout)
          rescue StandardError, ScriptError
            # Thread#join re-raises whatever killed the thread. It was already
            # reported where it happened, and a worker shutting down must not
            # inherit the listener's crash.
            true
          end

        thread.kill unless joined
        self
      end

      # POST-FORK ONLY. The connection's socket is shared with the parent
      # process, so `disconnect!` would send a termination packet down the
      # parent's session and kill the listener that is still working there.
      # `discard!` only drops our end of the file descriptor. There is no thread
      # to join in a forked child (only the forking thread survives), so this
      # never waits.
      def discard!
        @stopping = true
        @discarded = true
        begin
          @connection&.discard!
        rescue StandardError
          nil
        end
        @thread = nil
        self
      end

      def alive?
        @thread&.alive? || false
      end

      def stopping?
        @stopping
      end

      private
        attr_reader :registry, :connection_provider, :wait_timeout, :keepalive_interval,
                    :reconnect_wait, :reporting_threshold, :now, :error_reporter

        def join_timeout
          (2 * wait_timeout) + 1
        end

        def run
          until stopping?
            begin
              connect_and_listen
              wait_loop
            rescue *self.class.connection_errors => e
              handle_connection_error(e)
            end
          end
        rescue StandardError, ScriptError => e
          # Not a connection error: the thread is going to die. Make sure it is
          # never silent before letting it go. ScriptError is in the list because
          # a misconfigured connection provider raises NotImplementedError, which
          # is not a StandardError.
          @fatal_error = e
          report_error(e)
          announce_death(e)
          raise
        ensure
          safe_disconnect unless @discarded
          instrument_shutdown
        end

        # Tells the registry the listener is gone for good, so that the workers
        # it was serving are put back on their own polling intervals instead of
        # being left at the raised one with nothing to wake them.
        def announce_death(error)
          registry.listener_crashed(self, error) if registry.respond_to?(:listener_crashed)
        rescue StandardError, ScriptError
          nil
        end

        def connect_and_listen
          @connection = connection_provider.call
          @connection.execute("SET application_name = #{@connection.quote(resolved_application_name)}")
          @connection.execute("LISTEN #{@connection.quote_column_name(channel)}")
          @last_keepalive = now.call

          # Reaching here means the connection works, so nothing before it counts
          # towards the reporting threshold any more. Without this, a connection
          # that flaps faster than `keepalive_interval` — connect, drop, connect,
          # drop — never reaches a notification or a keepalive to reset the
          # counter, so it climbs past the threshold once and then reports EVERY
          # subsequent failure, forever.
          @consecutive_failures = 0

          # Not `start`: ActiveSupport::Subscriber reserves `start` and `finish`
          # for the notifier protocol and silently refuses to subscribe a
          # LogSubscriber method with either name.
          instrument(:start_listener, pid: ::Process.pid, channel: channel)
        end

        # Resolved on every (re)connect so that a value computed from the pid is
        # correct in a process that forked after boot.
        def resolved_application_name
          @application_name.respond_to?(:call) ? @application_name.call : @application_name
        end

        def wait_loop
          until stopping?
            # Defense in depth against a fork whose child somehow kept running
            # this thread: never touch a socket that belongs to the parent.
            break if ::Process.pid != @started_pid

            @connection.raw_connection.wait_for_notify(wait_timeout) do |_channel, _pid, payload|
              handle_notification(payload)
            end

            tick_keepalive
          end
        end

        def handle_notification(payload)
          @consecutive_failures = 0
          queue_name = payload.to_s
          dispatched = false

          instrument(:notify, queue_name: queue_name) do |event|
            dispatched = true
            counts = registry.dispatch(queue_name)
            event.merge!(counts) if counts.is_a?(Hash)
          end

          # ActiveSupport runs a plain `subscribe` block AFTER the instrumented
          # block, so a subscriber that raises has not stopped the fan-out above
          # from happening. The rarer `subscribe(name, object_responding_to_start)`
          # form does run before it, though, and a notification dropped because
          # somebody's metrics object raised would be a job left waiting for the
          # next poll.
          registry.dispatch(queue_name) unless dispatched
        end

        def tick_keepalive
          return if now.call - @last_keepalive < keepalive_interval

          instrument(:keepalive, pid: ::Process.pid) do
            @connection.raw_connection.async_exec("SELECT 1").clear
            @consecutive_failures = 0
            registry.sweep_dead_workers
            @last_keepalive = now.call
          end
        end

        def handle_connection_error(error)
          @consecutive_failures += 1
          reported = @consecutive_failures > reporting_threshold

          instrument :reconnect,
            error: error.class.name,
            message: error.message,
            consecutive_failures: @consecutive_failures,
            reported: reported,
            wait: reconnect_wait

          report_error(error) if reported
          safe_disconnect
          interruptible_wait(reconnect_wait)
        end

        # Every instrumented event on this thread goes through here, because an
        # application's own `ActiveSupport::Notifications` subscriber is
        # arbitrary third-party code running on OUR thread: a bug in somebody's
        # metrics block used to propagate straight out of the run loop and kill
        # the listener permanently — for the lifetime of the process, with the
        # workers left at a raised polling interval.
        #
        # An exception raised by the instrumented BLOCK still propagates: those
        # are ours, and a connection error inside a keepalive has to reach the
        # reconnect path. Only a subscriber's exception is swallowed, and it is
        # reported once per exception class so that a subscriber raising on every
        # notification cannot turn into a flood of its own.
        def instrument(event, **payload)
          block_error = nil

          begin
            ListenNotify.instrument(event, **payload) do |event_payload|
              begin
                yield event_payload if block_given?
              rescue StandardError, ScriptError => e
                block_error = e
                raise
              end
            end
          rescue StandardError, ScriptError => e
            raise block_error if block_error

            report_subscriber_error(e)
          end
        end

        def report_subscriber_error(error)
          key = error.class
          return if @reported_subscriber_errors.key?(key)

          @reported_subscriber_errors[key] = true
          report_error(error)
        rescue StandardError, ScriptError
          nil
        end

        def report_error(error)
          if error_reporter
            error_reporter.call(error)
          elsif defined?(::SolidQueue) && ::SolidQueue.respond_to?(:on_thread_error)
            ::SolidQueue.on_thread_error&.call(error)
          end
        rescue StandardError
          # An error reporter that itself fails must not take the process down.
          nil
        end

        # Best effort on both statements: this runs on connections we already
        # know may be broken.
        def safe_disconnect
          connection = @connection
          @connection = nil
          return if connection.nil?

          begin
            connection.execute("UNLISTEN #{connection.quote_column_name(channel)}")
          rescue StandardError
            nil
          end

          begin
            connection.disconnect!
          rescue StandardError
            nil
          end
        end

        # Sleeps in wait_timeout-sized slices so that #stop is never delayed by
        # a long reconnect backoff. Deliberately uses real time rather than the
        # injected clock, which only drives the keepalive schedule.
        def interruptible_wait(duration)
          remaining = duration.to_f

          while remaining > 0 && !stopping?
            slice = wait_timeout > 0 ? [ wait_timeout, remaining ].min : remaining
            sleep slice
            remaining -= slice
          end
        end

        def instrument_shutdown
          payload = { pid: ::Process.pid }
          if @fatal_error
            payload[:error] = @fatal_error.class.name
            payload[:message] = @fatal_error.message
          end

          instrument(:shutdown, **payload)
        rescue StandardError
          nil
        end
    end
  end
end

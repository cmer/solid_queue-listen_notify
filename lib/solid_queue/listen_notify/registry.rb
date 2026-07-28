# frozen_string_literal: true

require_relative "queue_matcher"
require_relative "listener"

module SolidQueue
  module ListenNotify
    # Per-process multiplexer between the single listener thread and the workers
    # running in this process (async mode runs N workers in one process, and one
    # LISTEN connection has to serve all of them).
    #
    # Locking discipline, in one place so it can be checked at a glance:
    #
    # * @mutex only ever guards in-memory bookkeeping (@workers, @listener).
    # * It is NEVER held while calling worker.wake_up or listener.stop: waking
    #   writes to a worker's self-pipe and stopping joins a thread, and blocking
    #   there with the lock held would stall every other worker's registration.
    # * Building and starting the listener DOES happen under the lock. Both are
    #   non-blocking (a couple of ivars plus Thread.new) and doing it atomically
    #   is what guarantees "at most one listener per non-empty transition" when
    #   several worker threads register concurrently.
    # * #dispatch runs on the listener thread and performs zero database work.
    class Registry
      class << self
        # A class-level ivar rather than a constant, because the fork hook has to
        # be able to REPLACE it: fork() copies only the calling thread, and this
        # gem does not want the first `Registry.instance` in a child depending on
        # the interpreter having released a lock its owner never will. See
        # ListenNotify.after_fork. A constant cannot be reassigned without a
        # warning; this can.
        attr_reader :creation_lock

        def instance
          @instance || creation_lock.synchronize { @instance ||= new }
        end

        # Lets callers act on a registry only if there already is one. Nothing
        # should build a registry just to shut a worker down, or just to walk
        # through a fork hook.
        def instantiated?
          !@instance.nil?
        end

        # Drops the current instance entirely, stopping (or, after a fork,
        # discarding) whatever listener it owned. Used by tests and by anything
        # that needs a clean slate in a child process.
        def reset!
          previous = creation_lock.synchronize do
            instance = @instance
            @instance = nil
            instance
          end

          previous&.shutdown_for_reset!
          nil
        end

        # Everything a forked child has to do to the registry, in the order it
        # has to happen: a usable creation lock first, so that the instance
        # guard below — and anything that races with it — cannot deadlock.
        def after_fork!
          @creation_lock = Mutex.new
          @instance&.guard_fork!
          nil
        end
      end

      @creation_lock = Mutex.new

      def initialize(listener_factory: nil)
        @listener_factory = listener_factory || method(:build_default_listener)
        @mutex = Mutex.new
        @workers = {}
        @listener = nil
        @pid = ::Process.pid
      end

      def register(worker)
        guard_fork!

        @mutex.synchronize do
          sweep_dead_locked
          @workers[worker] ||= snapshot_queues(worker)
          start_listener_locked
        end

        self
      end

      def deregister(worker)
        guard_fork!

        listener = @mutex.synchronize do
          @workers.delete(worker)
          take_listener_if_empty_locked
        end

        # Deliberately does not join. This runs on Solid Queue's shutdown path,
        # inside a 5-second budget shared with everything else a worker has to
        # do, and a join here spent up to `2 * wait_timeout + 1` seconds of it
        # waiting for a thread that is already unwinding on its own. The latch
        # is enough: the loop notices within one `wait_timeout` and its `ensure`
        # closes the connection.
        listener&.stop(join: false)
        self
      end

      # Called BY THE LISTENER THREAD, from its fatal rescue, just before the
      # thread dies for good. Detaching the listener here is what lets a later
      # register() build a fresh one; restoring polling intervals is what keeps
      # the death from being worse than never having installed the gem.
      def listener_crashed(listener, error = nil)
        guard_fork!

        stranded = nil

        detached = @mutex.synchronize do
          next false unless @listener.equal?(listener)

          @listener = nil
          stranded = @workers.keys
          true
        end

        # Outside the lock: restoring an interval and waking a worker both reach
        # into Solid Queue, and neither may run with our mutex held.
        ListenNotify.listener_crashed(error, stranded) if detached

        self
      end

      # Called FROM THE LISTENER THREAD for every notification. No fork guard
      # here on purpose: the listener does its own pid check before ever reading
      # from its socket, and this path must stay allocation-cheap and DB-free.
      #
      # Returns the counts the listener merges into its instrumentation payload.
      def dispatch(queue_name)
        pairs = @mutex.synchronize { @workers.to_a }
        wake_saturated = ListenNotify.wake_saturated_workers
        woken = 0
        skipped_saturated = 0
        unreachable = nil

        pairs.each do |worker, queues|
          next unless QueueMatcher.matches?(queues, queue_name)

          if !wake_saturated && pool_saturated?(worker)
            skipped_saturated += 1
            next
          end

          begin
            worker.wake_up
            woken += 1
          rescue StandardError
            # A dead self-pipe (or any other wake failure) means the worker is
            # gone: reap it rather than failing the whole fan-out.
            (unreachable ||= []) << worker
          end
        end

        reap(unreachable) if unreachable

        { woken: woken, skipped_saturated: skipped_saturated }
      end

      # Called from the listener's keepalive tick. Covers the case where a
      # worker went away without on_worker_stop ever running (SIGQUIT, or
      # AsyncSupervisor replacing a thread).
      def sweep_dead_workers
        listener = @mutex.synchronize do
          was_populated = @workers.any?
          sweep_dead_locked
          was_populated ? take_listener_if_empty_locked : nil
        end

        # Runs on the listener thread, so #stop only latches anyway.
        listener&.stop(join: false)
        self
      end

      def workers
        @mutex.synchronize { @workers.keys }
      end

      def listener
        @mutex.synchronize { @listener }
      end

      # Entry-point guard for the fork case (Puma clustered + async plugin).
      # The listener's connection was removed from its pool, so ActiveRecord's
      # own discard_pools! never sees it: we have to discard it ourselves, and
      # discard (not disconnect) because the socket still belongs to the parent.
      def guard_fork!
        return self if @pid == ::Process.pid

        parent_pid = @pid
        listener = @listener

        # fork() only copies the calling thread, so a mutex another thread held
        # at fork time would stay locked forever in the child. We are
        # single-threaded here: replace it instead of trying to take it.
        @mutex = Mutex.new
        @listener = nil
        @workers = {}
        @pid = ::Process.pid

        ListenNotify.instrument(:fork_detected, parent_pid: parent_pid, pid: @pid)
        listener&.discard!
        self
      end

      def shutdown_for_reset!
        forked = @pid != ::Process.pid
        @mutex = Mutex.new if forked

        listener = @mutex.synchronize do
          current = @listener
          @listener = nil
          @workers = {}
          current
        end

        return nil if listener.nil?

        forked ? listener.discard! : listener.stop
        nil
      end

      private
        # Caller holds @mutex.
        def start_listener_locked
          return if @workers.empty?
          return if @listener&.alive?

          @listener = @listener_factory.call(self)
          @listener.start
        end

        # Caller holds @mutex. Returns the listener to stop OUTSIDE the lock,
        # having already detached it, so the caller can never stop a listener
        # that a concurrent register has since revived.
        def take_listener_if_empty_locked
          return nil unless @workers.empty?

          listener = @listener
          @listener = nil
          listener
        end

        # Caller holds @mutex.
        def sweep_dead_locked
          @workers.delete_if { |worker, _queues| !worker_alive?(worker) }
        end

        def reap(workers)
          listener = @mutex.synchronize do
            workers.each { |worker| @workers.delete(worker) }
            take_listener_if_empty_locked
          end

          # Safe even though this runs on the listener thread: Listener#stop
          # detects a self-stop and only latches instead of joining.
          listener&.stop(join: false)
        end

        # Every call into a worker is defensive: these are public-by-visibility
        # Solid Queue APIs, and if any of them drifts we want to degrade to
        # "wake it anyway" / "keep it registered" rather than to silence.
        def worker_alive?(worker)
          worker.alive?
        rescue StandardError
          true
        end

        def pool_saturated?(worker)
          !worker.pool.idle?
        rescue StandardError
          false
        end

        def snapshot_queues(worker)
          Array(worker.queues).map { |queue| queue.to_s }.freeze
        rescue StandardError
          [ "*" ].freeze
        end

        # The module's connection provider is a pool checkout pinned to the
        # writing role, then removed from the pool. It is only ever nil if
        # somebody cleared it deliberately, and a listener that cannot connect
        # should say so rather than fail silently.
        def build_default_listener(registry)
          provider = ListenNotify.connection_provider || method(:raise_missing_connection_provider)
          Listener.new(registry: registry, connection_provider: provider)
        end

        def raise_missing_connection_provider
          raise NotImplementedError, "No connection provider configured for SolidQueue::ListenNotify::Listener. " \
            "Build the registry with a listener_factory that injects one."
        end
    end
  end
end

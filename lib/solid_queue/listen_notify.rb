# frozen_string_literal: true

require "logger"

require "active_support"
require "active_support/core_ext/module/attribute_accessors"
require "active_support/core_ext/numeric/time"

require_relative "listen_notify/version"
require_relative "listen_notify/queue_matcher"
require_relative "listen_notify/trigger_installer"
require_relative "listen_notify/connection_provider"
require_relative "listen_notify/preflight"
require_relative "listen_notify/listener"
require_relative "listen_notify/registry"
require_relative "listen_notify/log_subscriber"

module SolidQueue
  module ListenNotify
    # NOTE for anyone editing this gem: inside `module SolidQueue`, a bare
    # `Process` resolves to SolidQueue::Process — the ActiveRecord model — and
    # not to Ruby's. Every reference to the real one, here and in the other
    # files, is spelled `::Process` for that reason.
    extend self

    # Seeds the default for applications that never set `enabled` themselves.
    # An application that does set it wins here — but not in `enabled?`, which
    # re-reads the variable so that it works as an emergency kill switch either
    # way. See the comment there.
    mattr_accessor :enabled, default: ENV.fetch("SOLID_QUEUE_LISTEN_NOTIFY_ENABLED", "true") != "false"

    mattr_accessor :channel, default: "solid_queue_ready"

    # nil means "never touch the workers' polling interval".
    mattr_accessor :fallback_polling_interval, default: 10.seconds

    mattr_accessor :listen_database
    # Installing the trigger at boot whenever it is missing is the default
    # because schema.rb does not dump triggers: without this, every database
    # created with db:schema:load would silently lack it. Needs a database user
    # allowed to CREATE FUNCTION / CREATE TRIGGER; a failed install degrades to
    # the :trigger_missing banner, never a crash.
    mattr_accessor :auto_install_trigger, default: true
    mattr_accessor :wake_saturated_workers, default: false

    mattr_accessor :wait_timeout, default: 1.second
    mattr_accessor :keepalive_interval, default: 10.seconds
    mattr_accessor :reconnect_wait, default: 5.seconds
    mattr_accessor :connection_errors_reporting_threshold, default: 6

    # Anything that responds to #call and returns a pool-removed PostgreSQL
    # connection. Replaceable, but the default is what you want.
    mattr_accessor :connection_provider, default: ConnectionProvider.new

    mattr_writer :application_name

    # Class variables rather than constants so that reloading this file (which
    # the configuration test does, to exercise the env kill switch) doesn't warn.
    @@preflight_lock = Mutex.new
    @@preflight_result = nil
    @@fallback_logger = nil

    # `SOLID_QUEUE_LISTEN_NOTIFY_ENABLED=false` is documented as a kill switch
    # that needs no deploy, and an application that sets `enabled` explicitly —
    # to either value — would otherwise overwrite the mattr default and take
    # that switch away. So it is checked here too, and it only ever turns the
    # gem OFF: the variable can never enable the gem against a configuration
    # that disabled it.
    def enabled?
      return false if ENV["SOLID_QUEUE_LISTEN_NOTIFY_ENABLED"] == "false"

      enabled
    end

    # Resolved on every call: a process that forks after boot must not report the
    # parent's pid.
    def application_name
      @@application_name || "solid_queue-listen_notify [#{::Process.pid}]"
    end

    # Everything this gem says goes through Solid Queue's logger. The fallback is
    # not a nicety: the loudest messages here are the ones explaining why the gem
    # is INACTIVE, and losing them because Solid Queue isn't loaded (or has no
    # logger) would defeat their entire purpose.
    def logger
      if defined?(::SolidQueue) && ::SolidQueue.respond_to?(:logger) && (solid_queue_logger = ::SolidQueue.logger)
        solid_queue_logger
      else
        @@fallback_logger ||= ::Logger.new($stdout)
      end
    end

    def instrument(event, **payload, &block)
      ActiveSupport::Notifications.instrument("#{event}.solid_queue_listen_notify", **payload, &block)
    end

    # Called from Solid Queue's on_worker_start hook. Rescued end to end: a
    # raising lifecycle hook is handed to handle_thread_error, and something that
    # is only an optimization must never be the reason a worker looks broken.
    def register(worker)
      return nil unless operational?

      restore_to = raise_polling_interval(worker)
      Registry.instance.register(worker, restore_interval: restore_to)

      # Instrumented only once the registry has recorded the override, so that
      # a subscriber raising here finds the bookkeeping already consistent — it
      # can never strand a raised interval that nobody remembers.
      if restore_to
        instrument :override_polling_interval,
          worker_name: worker_name(worker), from: restore_to, to: fallback_polling_interval.to_f
      end
      nil
    rescue StandardError, ScriptError => e
      # A worker left polling every 10 seconds with nothing to wake it is the one
      # failure this gem must never cause, so an interval we raised is put back
      # if anything after it goes wrong.
      restore_polling_interval(worker, restore_to)
      log_degradation("register a worker", e)
    end

    # on_worker_stop is not guaranteed to run at all (a supervisor that exceeds
    # its shutdown timeout exits without callbacks), so this is a convenience,
    # never the thing cleanup depends on.
    #
    # Never instantiate the registry just to deregister: this hook also runs in
    # processes where nothing ever registered, and building a registry there
    # would be building one that only exists to be empty.
    def deregister(worker)
      return nil unless Registry.instantiated?

      Registry.instance.deregister(worker)
      nil
    rescue StandardError, ScriptError => e
      log_degradation("deregister a worker", e)
    end

    # Called by the registry when the listener thread died for good — a fatal,
    # non-connection error, which no reconnect will fix. `stranded` is the
    # registry's list of [worker, original_interval] pairs; the interval is nil
    # for workers whose interval was never raised.
    #
    # The gem raised these workers' polling intervals on the strength of a
    # promise it can no longer keep, and a worker left polling every 10 seconds
    # with nothing to wake it is strictly worse than never having installed the
    # gem. So the promise is withdrawn: every interval we raised goes back, every
    # worker is woken so it re-reads it rather than finishing its current sleep,
    # and the whole thing is said out loud.
    def listener_crashed(error, stranded)
      restored = Array(stranded).count { |worker, interval| restore_override(worker, interval) }
      announce_listener_death(error, restored)
      nil
    rescue StandardError, ScriptError => e
      log_degradation("restore polling intervals after the listener died", e)
    end

    # Whether the gem verified, in this process, that it can actually deliver
    # notifications. Memoized per pid: the preflight opens connections and runs a
    # two-second self-test, so it must not run once per worker — but a forked
    # child gets its own verdict, because it also gets its own connections.
    def operational?
      result = @@preflight_result
      return result.operational? if fresh?(result)

      @@preflight_lock.synchronize do
        result = @@preflight_result

        unless fresh?(result)
          result = Preflight.new.run
          @@preflight_result = result
        end
      end

      result.operational?
    end

    # Called from ActiveSupport::ForkTracker in the child.
    #
    # fork() copies only the calling thread, so every lock this process held at
    # fork time is inherited with no thread left alive to release it. CRuby
    # papers over that itself — rb_thread_atfork abandons the mutexes held by
    # threads that did not survive — so on the runtimes this gem supports today
    # the replacements below are belt and braces rather than a live fix.
    #
    # They are here anyway because the exposure is asymmetric. The widest window
    # belongs to the preflight lock: `operational?` holds it across connecting to
    # Postgres and a self-test that waits up to two seconds, and a child that
    # inherited it locked would hang the first worker to register — permanently,
    # inside a lifecycle hook, with no error and no output. Replacing a mutex in
    # a process that is still single-threaded costs nothing, and it means the
    # gem is not relying on an interpreter implementation detail to avoid its
    # worst failure mode.
    #
    # Order matters: the lock first, then the guards that use it. The preflight
    # VERDICT needs no reset (it is stamped with the pid that reached it, so a
    # child recomputes its own).
    def after_fork
      @@preflight_lock = Mutex.new

      connection_provider.forget_pools! if connection_provider.respond_to?(:forget_pools!)
      Registry.after_fork!
      nil
    rescue StandardError, ScriptError => e
      log_degradation("handle a fork", e)
    end

    # Copies `config.solid_queue_listen_notify` onto the module. OrderedOptions
    # only yields the keys that were actually set, so defaults are never
    # overwritten with nil.
    def apply_configuration(options)
      return nil if options.nil?

      options.each do |name, value|
        if respond_to?("#{name}=")
          public_send("#{name}=", value)
        else
          # Not fatal: a typo in an optional optimization's configuration should
          # not stop an application from booting. It should be impossible to
          # miss, though.
          logger&.warn("SolidQueue-ListenNotify ignoring unknown configuration option #{name.inspect}")
        end
      end

      nil
    end

    # Clears memoized state, mainly for tests and for anything that needs the
    # preflight to run again after reconfiguring.
    def reset!
      @@preflight_lock.synchronize { @@preflight_result = nil }
      connection_provider.reset! if connection_provider.respond_to?(:reset!)
      nil
    end

    # ActiveRecord touchpoints -------------------------------------------------
    #
    # Every reference to Solid Queue's model, and therefore to ActiveRecord, is
    # resolved here and inside a method body. Requiring this gem has to work in a
    # process where neither is loaded; the unit suite never loads them, which is
    # what keeps that honest.

    def queue_record
      ::SolidQueue::Record
    end

    # Read off the pool's configuration rather than off a connection: this runs
    # at boot, in every process, and must not force a connection to a database we
    # may not even support.
    def queue_database_adapter
      queue_record.connection_pool.db_config.adapter.to_s
    end

    def writing_role
      if defined?(::ActiveRecord) && ::ActiveRecord.respond_to?(:writing_role)
        ::ActiveRecord.writing_role
      else
        :writing
      end
    end

    # A LISTEN on a replica hears nothing, so connections are pinned to the
    # writing role. `connected_to` refuses to run on a class that never called
    # `connects_to` ("only allowed on the abstract class that established the
    # connection"), which is exactly the plain single-database app — where there
    # is one role anyway and the block can simply run. The `entered` flag is what
    # keeps a NotImplementedError raised BY THE BLOCK from running it twice.
    def with_writing_role
      entered = false

      queue_record.connected_to(role: writing_role) do
        entered = true
        yield
      end
    rescue NotImplementedError
      raise if entered
      yield
    end

    def with_queue_connection(&block)
      with_writing_role { queue_record.connection_pool.with_connection(&block) }
    end

    private
      def fresh?(result)
        !result.nil? && result.pid == ::Process.pid
      end

      # Only ever raises the interval, never lowers it: a worker configured to
      # poll every 30s asked for that, and a gem that quietly polled more often
      # than the application wanted would be a pessimization. Safe to raise at
      # all only because operational? proved notifications arrive.
      #
      # Returns the interval that was replaced, or nil when nothing changed.
      # Deliberately does NOT instrument: the caller does, once the registry
      # has recorded what happened here.
      def raise_polling_interval(worker)
        target = fallback_polling_interval&.to_f
        return nil if target.nil?
        return nil unless worker.respond_to?(:polling_interval) && worker.respond_to?(:polling_interval=)

        current = worker.polling_interval
        return nil if current.nil? || target <= current.to_f

        worker.polling_interval = target
        current
      end

      def restore_polling_interval(worker, previous)
        return if previous.nil?

        worker.polling_interval = previous
      rescue StandardError
        nil
      end

      # Puts one worker back on the interval the registry remembered for it and
      # wakes it, so that it re-reads the interval now rather than at the end of
      # the sleep it is already in. Returns whether anything was restored.
      def restore_override(worker, previous)
        return false if previous.nil?

        current = current_polling_interval(worker)
        worker.polling_interval = previous
        instrument :override_polling_interval,
          worker_name: worker_name(worker), from: current, to: previous, restored: true

        begin
          worker.wake_up
        rescue StandardError
          nil
        end

        true
      rescue StandardError, ScriptError
        false
      end

      def current_polling_interval(worker)
        worker.polling_interval if worker.respond_to?(:polling_interval)
      rescue StandardError
        nil
      end

      def announce_listener_death(error, restored)
        logger&.error(
          "SolidQueue-ListenNotify listener died permanently " \
          "(#{error ? "#{error.class}: #{error.message}" : "cause unknown"}); " \
          "#{restored} worker(s) restored to their original polling intervals. " \
          "Notifications are no longer being delivered in this process — it is back to plain polling."
        )
      rescue StandardError
        nil
      end

      def worker_name(worker)
        worker.name if worker.respond_to?(:name)
      rescue StandardError
        nil
      end

      def log_degradation(action, error)
        logger&.warn("SolidQueue-ListenNotify could not #{action} (#{error.class}: #{error.message}) – " \
          "continuing without notifications")
        nil
      rescue StandardError
        nil
      end
  end
end

require_relative "listen_notify/railtie" if defined?(::Rails::Railtie)

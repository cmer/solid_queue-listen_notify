# frozen_string_literal: true

module SolidQueue
  module ListenNotify
    # Hands out the dedicated connection that the listener thread (and the
    # preflight's self-test) run on: an ActiveRecord PostgreSQL adapter
    # connection that has been REMOVED from its pool.
    #
    # Removing it is the whole point. A connection parked in wait_for_notify for
    # the lifetime of the process would otherwise be a connection permanently
    # missing from the pool, and any code that checked it out would find itself
    # sharing a socket with the listener thread. The price is that ActiveRecord
    # no longer knows the connection exists: nobody else will close it (the
    # listener disconnects it itself) and `discard_pools!` after a fork will not
    # reach it (the registry's fork guard does).
    #
    # Everything ActiveRecord-shaped in here is resolved inside method bodies:
    # requiring this file must not require ActiveRecord.
    class ConnectionProvider
      # Best-effort teardown for a connection this provider handed out: nobody
      # else can close it (it was removed from its pool), and it may already be
      # broken, so both statements are attempted and both failures swallowed.
      def self.release(connection, channel:)
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

        nil
      end

      def initialize
        @mutex = Mutex.new
        @pools = {}
      end

      def call
        if (database = ListenNotify.listen_database)
          checkout(isolated_pool(database))
        else
          checkout_from_queue_pool
        end
      end

      # Drops the memoized isolated pools. The connections handed out so far are
      # not affected: they were removed from those pools and belong to whoever
      # asked for them.
      def reset!
        pools = @mutex.synchronize do
          previous = @pools
          @pools = {}
          previous
        end

        pools.each_value do |pool|
          pool.disconnect!
        rescue StandardError
          nil
        end

        nil
      end

      # POST-FORK ONLY, and the counterpart to Registry#guard_fork!.
      #
      # A memoized isolated pool does NOT survive a fork. ActiveRecord's own
      # after_fork hook calls PoolConfig.discard_pools!, which discards every
      # pool it knows about — including the one behind our private handler, which
      # it knows about because establish_connection registered it. What we keep
      # is a reference to a pool object whose innards have been thrown away, and
      # the first `pool.checkout` in the child fails. Without this, the gem is
      # silently inactive in every forked child of a process that ever used
      # `listen_database`.
      #
      # Deliberately does NOT disconnect anything: those pools were discarded
      # already, and whatever sockets they held belong to the parent.
      #
      # Replaces the mutex rather than taking it, for the same reason the
      # registry's fork guard does: fork() copies only the calling thread, and
      # nothing here should depend on the interpreter releasing a lock whose
      # owner did not survive. See ListenNotify.after_fork.
      def forget_pools!
        @mutex = Mutex.new
        @pools = {}
        nil
      end

      private
        def checkout_from_queue_pool
          connection = nil

          # Pinned to the writing role: a LISTEN on a replica hears nothing.
          ListenNotify.with_writing_role do
            connection = checkout(ListenNotify.queue_record.connection_pool)
          end

          connection
        end

        def checkout(pool)
          connection = pool.checkout
          pool.remove(connection)
          connection
        end

        # `listen_database` exists to bypass a transaction-mode pooler, so the
        # connection it names must not come from the application's own pools:
        # it gets a private handler, and therefore a private pool, of its own.
        #
        # Keyed by pid as well as by name: belt and braces behind
        # `forget_pools!`, so that a child which somehow never ran the fork hook
        # still builds its own pool instead of reaching into a discarded one.
        def isolated_pool(database)
          key = [ ::Process.pid, database.to_s ]

          @mutex.synchronize do
            @pools[key] ||= establish_isolated_pool(key.last)
          end
        end

        def establish_isolated_pool(name)
          handler = ::ActiveRecord::ConnectionAdapters::ConnectionHandler.new

          handler.establish_connection \
            resolve_database_config(name),
            owner_name: ListenNotify.queue_record,
            role: ListenNotify.writing_role
        end

        def resolve_database_config(name)
          configurations = ::ActiveRecord::Base.configurations

          # configs_for returns nil for an unknown name; resolve raises with a
          # message naming the entry we couldn't find, which is what the user
          # needs to see.
          configurations.configs_for(env_name: environment, name: name) || configurations.resolve(name.to_sym)
        end

        def environment
          if defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env
            ::Rails.env.to_s
          else
            ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
          end
        end
    end
  end
end

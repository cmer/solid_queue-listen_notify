# frozen_string_literal: true

require_relative "trigger_installer"

module SolidQueue
  module ListenNotify
    # Decides whether the gem can actually deliver notifications in this process,
    # and — when it can't — says so loudly enough that nobody has to discover it
    # months later through a latency graph.
    #
    # Two rules shape the whole class:
    #
    # * It NEVER raises. It runs from a worker's start hook, at boot, against a
    #   database that may well be down; an exception here would land in Solid
    #   Queue's thread-error handler on behalf of something that is only an
    #   optimization. Every failure degrades to "not operational", which leaves
    #   workers polling exactly as they would without the gem installed.
    # * Every dependency is injected, so the decision tree is unit-testable
    #   without Postgres, and every default is resolved lazily, so requiring this
    #   file never touches ActiveRecord.
    class Preflight
      SELF_TEST_PAYLOAD = "preflight"
      SELF_TEST_TIMEOUT = 2

      INSTALL_COMMAND = "bin/rails generate solid_queue:listen_notify:install --database queue && bin/rails db:migrate"

      BANNER_RULE = "=" * 78

      # The verdict, plus the pid it was reached in: memoizing across a fork
      # would be memoizing a decision about somebody else's connection.
      class Result
        attr_reader :reason, :details, :pid

        def initialize(operational:, reason: nil, details: nil, pid: ::Process.pid)
          @operational = operational
          @reason = reason
          @details = details
          @pid = pid
        end

        def operational?
          @operational
        end
      end

      attr_reader :channel

      # * with_connection    — yields a POOLED connection (checked back in after
      #                        the block); used for the cheap checks.
      # * connection_provider — produces the pool-removed connection the listener
      #                        will use; the self-test has to run on that one,
      #                        because it is that connection's path to Postgres
      #                        we are testing.
      def initialize(channel: nil, with_connection: nil, adapter_name: nil, connection_provider: nil,
                     trigger_installer: nil, logger: nil, self_test_timeout: SELF_TEST_TIMEOUT)
        @channel = (channel || ListenNotify.channel).to_s
        @with_connection = with_connection
        @adapter_name = adapter_name
        @connection_provider = connection_provider
        @trigger_installer = trigger_installer
        @logger = logger
        @self_test_timeout = self_test_timeout
        @install_error = nil
      end

      # Always returns a Result, always instruments exactly once.
      def run
        result = nil

        ListenNotify.instrument(:preflight, channel: channel) do |payload|
          result = evaluate
          payload[:operational] = result.operational?
          payload[:reason] = result.reason
          payload[:details] = result.details if result.details
        end

        result
      rescue StandardError, ScriptError => e
        # Only instrumentation itself can get here (evaluate is fully rescued),
        # but the verdict still has to come out, and it still must not propagate.
        result || failure(:error, error: e.class.name, message: e.message)
      end

      private
        attr_reader :self_test_timeout

        def evaluate
          return failure(:disabled) unless ListenNotify.enabled?
          # Before anything that costs a connection: a channel Postgres cannot
          # accept makes every enqueue in the application raise, and no other
          # check would notice.
          return invalid_channel unless TriggerInstaller.channel_valid?(channel)

          adapter = adapter_name.to_s
          return unsupported_adapter(adapter) unless adapter.match?(/postg/i)

          failed = check_database(adapter)
          return failed if failed

          check_notifications
        rescue StandardError, ScriptError => e
          error_failure(e)
        end

        # Everything that can be answered from a pooled connection, so that a
        # broken setup never holds a connection out of the pool.
        def check_database(adapter)
          failed = nil

          with_connection do |connection|
            failed =
              if !connection.raw_connection.respond_to?(:wait_for_notify)
                unsupported_adapter(adapter, raw_connection: connection.raw_connection.class.name)
              else
                check_trigger(connection)
              end
          end

          failed
        end

        def check_trigger(connection)
          installer = trigger_installer_for(connection)

          install_trigger(installer) if !installer.installed? && ListenNotify.auto_install_trigger
          return trigger_missing unless installer.installed?

          definition = installer.function_definition
          return channel_mismatch unless notifies_our_channel?(definition)

          nil
        end

        # Looks for the whole `pg_notify('<channel>', NEW.queue_name)` call, not
        # merely for the channel name somewhere in the source. The function is
        # called solid_queue_listen_notify_ready, so a substring check passes for
        # channels named "ready", "notify", "listen", "queue" and a dozen other
        # plausible ones — it would have said "in sync" for a trigger notifying
        # something else entirely.
        def notifies_our_channel?(definition)
          definition.to_s.include?(TriggerInstaller.notify_call_for(channel))
        end

        def install_trigger(installer)
          installer.install!
        rescue StandardError => e
          # Almost always "permission denied": the credentials the app runs with
          # can't create functions or triggers. Treated as "still missing", so
          # the user gets the instructions below rather than a stack trace.
          @install_error = e
          nil
        end

        # The one check that cannot be faked out, and the reason it is worth the
        # two seconds: LISTEN on the connection the LISTENER will use, send the
        # NOTIFY through the pooled connection the TRIGGER will fire on, and see
        # whether it arrives. That is the real delivery path, end to end.
        #
        # Doing both halves on the one connection — as this used to — proves only
        # that Postgres delivers a session its own notifications. It catches a
        # transaction-mode pooler (PgBouncer discards the LISTEN, so nothing
        # comes back) but it is completely blind to a `listen_database` pointing
        # at the wrong database, where the LISTEN succeeds, the NOTIFY succeeds,
        # and no notification ever crosses between them.
        def check_notifications
          connection = connection_provider.call

          begin
            connection.execute("LISTEN #{connection.quote_column_name(channel)}")
            notify_from_queue_database

            if connection.raw_connection.wait_for_notify(self_test_timeout)
              success
            else
              self_test_failed
            end
          ensure
            # Nobody else can: this connection was removed from its pool.
            disconnect(connection)
          end
        end

        # Pooled, and therefore on the queue database — the one the trigger runs
        # in. Not inside a transaction, so Postgres delivers it immediately.
        def notify_from_queue_database
          with_connection do |connection|
            connection.execute(
              "NOTIFY #{connection.quote_column_name(channel)}, #{connection.quote(SELF_TEST_PAYLOAD)}"
            )
          end
        end

        def disconnect(connection)
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

        # Two statements, one connection: a transaction-mode pooler will very
        # likely serve them from two different backends. Only ever used to
        # enrich the self-test failure, never to decide anything.
        def backend_pid_changed?
          changed = false

          with_connection do |connection|
            first = connection.select_value("SELECT pg_backend_pid()")
            second = connection.select_value("SELECT pg_backend_pid()")
            changed = !first.nil? && first.to_s != second.to_s
          end

          changed
        rescue StandardError, ScriptError
          false
        end

        # Verdicts -------------------------------------------------------------

        def success
          Result.new(operational: true)
        end

        def failure(reason, **details)
          Result.new(operational: false, reason: reason, details: (details unless details.empty?))
        end

        def error_failure(error)
          failure(:error, error: error.class.name, message: error.message)
        end

        def unsupported_adapter(adapter, **details)
          warn_banner [
            "solid_queue-listen_notify requires PostgreSQL. Detected adapter: #{adapter}.",
            "The gem is INACTIVE — workers will use plain polling.",
            "Remove the gem or switch the queue database to PostgreSQL to silence this warning."
          ]

          failure(:unsupported_adapter, adapter: adapter, **details)
        end

        def trigger_missing
          lines = [
            "solid_queue-listen_notify is INACTIVE: the notification trigger is missing from",
            "#{TriggerInstaller::TABLE_NAME}, so nothing will ever be notified and workers will",
            "use plain polling. Install it with:",
            "",
            "  #{INSTALL_COMMAND}",
            "",
            "or leave `auto_install_trigger` on (it is the default) and give the database user",
            "permission to create functions and triggers, so the gem installs it by itself."
          ]
          lines += [ "", "The last automatic install attempt failed with: #{formatted_error(@install_error)}" ] if @install_error

          warn_banner(lines)

          failure(:trigger_missing, install_error: @install_error&.message)
        end

        def channel_mismatch
          warn_banner [
            "solid_queue-listen_notify is INACTIVE: the installed trigger does not notify on the",
            "configured channel (#{channel.inspect}). The channel was changed after the trigger was",
            "installed, so notifications would be sent where nobody is listening.",
            "Re-run the installer to bring the trigger back in sync:",
            "",
            "  #{INSTALL_COMMAND}"
          ]

          failure(:channel_mismatch, channel: channel)
        end

        def invalid_channel
          error_banner [
            "solid_queue-listen_notify is INACTIVE: the configured channel is not a channel name",
            "Postgres can accept.",
            "",
            "  #{TriggerInstaller.channel_error_message(channel)}",
            "",
            "LISTEN and NOTIFY would silently truncate it, and the trigger's pg_notify() would raise",
            "\"channel name too long\" on EVERY insert into #{TriggerInstaller::TABLE_NAME} —",
            "which is to say on every enqueue. Shorten `SolidQueue::ListenNotify.channel` and re-run",
            "the installer:",
            "",
            "  #{INSTALL_COMMAND}"
          ]

          failure(:invalid_channel, channel: channel, bytesize: channel.bytesize)
        end

        def self_test_failed
          pooler_suspected = backend_pid_changed?

          lines = [
            "solid_queue-listen_notify SELF-TEST FAILED: a NOTIFY sent from the queue database was",
            "not delivered to the listen connection within #{self_test_timeout}s. Notifications are not",
            "reaching this process.",
            "The most likely cause is PgBouncer (or another transaction-mode connection pooler)",
            "between the application and Postgres: transaction pooling silently discards LISTEN.",
            "",
            "Fix: point `SolidQueue::ListenNotify.listen_database` at a database.yml entry that",
            "connects DIRECTLY to Postgres, bypassing the pooler.",
            "",
            "If `listen_database` is ALREADY set, check that it names THE SAME database as the queue",
            "database — only the connection route may differ. A listen_database pointing at a",
            "different database connects and LISTENs happily and then never hears anything.",
            "",
            "The gem is INACTIVE — workers will use plain polling."
          ]

          if pooler_suspected
            lines += [
              "",
              "Backend PID changed between consecutive statements — this connection is almost",
              "certainly behind a transaction-mode pooler."
            ]
          end

          error_banner(lines)

          failure(:self_test_failed, timeout: self_test_timeout, backend_pid_changed: pooler_suspected)
        end

        # Injection seams ------------------------------------------------------

        # Reads the adapter off the pool's configuration rather than off a
        # connection: this runs in every process at boot and must not force a
        # connection to a database we may not even support.
        def adapter_name
          @adapter_name ? @adapter_name.call : ListenNotify.queue_database_adapter
        end

        def with_connection(&block)
          if @with_connection
            @with_connection.call(&block)
          else
            ListenNotify.with_queue_connection(&block)
          end
        end

        def connection_provider
          @connection_provider || ListenNotify.connection_provider
        end

        def trigger_installer_for(connection)
          if @trigger_installer
            @trigger_installer.call(connection)
          else
            TriggerInstaller.new(connection: connection, channel: channel)
          end
        end

        # Logging --------------------------------------------------------------

        def warn_banner(lines)
          banner(:warn, lines)
        end

        def error_banner(lines)
          banner(:error, lines)
        end

        # One call, so that a banner never comes out interleaved with another
        # thread's logging.
        def banner(severity, lines)
          logger&.public_send(severity, [ "", BANNER_RULE, *lines, BANNER_RULE ].join("\n"))
        rescue StandardError
          nil
        end

        # Resolved on every call so that a logger installed after boot (Rails
        # swaps Solid Queue's default one in an initializer) is the one used.
        def logger
          @logger || ListenNotify.logger
        end

        def formatted_error(error)
          [ error.class, error.message ].compact.join(" ")
        end
    end
  end
end

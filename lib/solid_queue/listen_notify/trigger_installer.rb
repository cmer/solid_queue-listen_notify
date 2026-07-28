# frozen_string_literal: true

module SolidQueue
  module ListenNotify
    # Creates (and removes) the AFTER INSERT trigger that turns every new row in
    # solid_queue_ready_executions into a pg_notify on the configured channel.
    #
    # The connection is always supplied by the caller: this class never touches a
    # pool, and never references SolidQueue::Record, so it stays usable from a
    # migration, from the preflight, or from a test with a fake connection.
    class TriggerInstaller
      FUNCTION_NAME = "solid_queue_listen_notify_ready"
      TRIGGER_NAME = "solid_queue_listen_notify"
      TABLE_NAME = "solid_queue_ready_executions"

      # CREATE OR REPLACE TRIGGER landed in Postgres 14.
      REPLACE_TRIGGER_MINIMUM_VERSION = 14_00_00

      # A notification channel is an identifier, and Postgres identifiers are
      # capped at NAMEDATALEN - 1 = 63 bytes. LISTEN/NOTIFY take it as an
      # identifier and TRUNCATE silently; pg_notify() takes it as text and
      # RAISES ("channel name too long") — from inside the trigger, which means
      # every INSERT into solid_queue_ready_executions fails. Refusing to
      # install such a trigger is the only way that error never reaches an
      # application's enqueue path.
      MAXIMUM_CHANNEL_BYTES = 63

      # The exact call the installed function body has to contain, spelled the
      # way `pg_get_functiondef` renders it back: the body is stored verbatim,
      # and a single quote inside the channel name comes back doubled. The
      # preflight's channel-drift check compares against this, so it can never
      # be satisfied by the channel merely appearing SOMEWHERE in the source —
      # including inside the gem's own function name.
      def self.notify_call_for(channel)
        "pg_notify('#{channel.to_s.gsub("'", "''")}', NEW.queue_name)"
      end

      def self.channel_valid?(channel)
        channel.to_s.bytesize.between?(1, MAXIMUM_CHANNEL_BYTES)
      end

      def self.channel_error_message(channel)
        "SolidQueue::ListenNotify.channel must be between 1 and #{MAXIMUM_CHANNEL_BYTES} bytes " \
          "(Postgres truncates longer identifiers in LISTEN/NOTIFY and pg_notify() rejects them " \
          "outright, which would make every enqueue raise). Got #{channel.to_s.bytesize} bytes: " \
          "#{channel.to_s.inspect}"
      end

      attr_reader :connection, :channel

      def initialize(connection:, channel: SolidQueue::ListenNotify.channel)
        @connection = connection
        @channel = channel
      end

      # Idempotent by construction: both paths end with the trigger and the
      # function defined exactly as below, whatever was there before.
      def install!
        validate_channel!

        ListenNotify.instrument(:install_trigger, channel: channel, database_version: database_version) do
          connection.execute(function_sql)

          if replace_trigger_supported?
            connection.execute(create_trigger_sql(replace: true))
          else
            connection.execute(drop_trigger_sql)
            connection.execute(create_trigger_sql(replace: false))
          end
        end
      end

      def uninstall!
        connection.execute(drop_trigger_sql)
        connection.execute(drop_function_sql)
      end

      # Resolved through the connection's search_path, so a trigger belonging to
      # another schema's copy of the table never counts as installed.
      def installed?
        truthy?(connection.select_value(installed_sql))
      end

      # Source of the installed function, or nil when it doesn't exist. Used to
      # detect a trigger left over from a different channel.
      def function_definition
        connection.select_value(function_definition_sql)
      end

      def function_sql
        <<~SQL
          CREATE OR REPLACE FUNCTION #{FUNCTION_NAME}() RETURNS trigger AS $$
          BEGIN
            PERFORM #{self.class.notify_call_for(channel)};
            RETURN NULL;
          END;
          $$ LANGUAGE plpgsql;
        SQL
      end

      def create_trigger_sql(replace: replace_trigger_supported?)
        <<~SQL
          CREATE#{" OR REPLACE" if replace} TRIGGER #{TRIGGER_NAME}
          AFTER INSERT ON #{TABLE_NAME}
          FOR EACH ROW EXECUTE FUNCTION #{FUNCTION_NAME}();
        SQL
      end

      def drop_trigger_sql
        "DROP TRIGGER IF EXISTS #{TRIGGER_NAME} ON #{TABLE_NAME};"
      end

      def drop_function_sql
        "DROP FUNCTION IF EXISTS #{FUNCTION_NAME}();"
      end

      # to_regclass resolves the table name through the connection's search_path
      # in exactly the way the INSERTs the trigger fires on do, so a trigger
      # installed on some other schema's solid_queue_ready_executions can never
      # read as installed. It returns NULL for a table that isn't there, and
      # `tgrelid = NULL` is never true, so a missing table is simply "not
      # installed" rather than an error.
      def installed_sql
        <<~SQL
          SELECT EXISTS (
            SELECT 1 FROM pg_trigger t
            WHERE t.tgrelid = to_regclass(#{connection.quote(TABLE_NAME)})
              AND t.tgname = #{connection.quote(TRIGGER_NAME)}
              AND NOT t.tgisinternal
          );
        SQL
      end

      def function_definition_sql
        <<~SQL
          SELECT pg_get_functiondef(p.oid) FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE p.proname = #{connection.quote(FUNCTION_NAME)}
            AND n.nspname = ANY(current_schemas(false))
          LIMIT 1;
        SQL
      end

      def database_version
        connection.database_version
      end

      private
        def validate_channel!
          return if self.class.channel_valid?(channel)

          raise ArgumentError, self.class.channel_error_message(channel)
        end

        def replace_trigger_supported?
          database_version >= REPLACE_TRIGGER_MINIMUM_VERSION
        end

        # The Postgres adapter casts booleans, but select_value goes through
        # whatever connection the caller handed us.
        def truthy?(value)
          value == true || value == "t"
        end
    end
  end
end

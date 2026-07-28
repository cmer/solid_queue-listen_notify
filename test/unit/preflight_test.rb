# frozen_string_literal: true

require "test_helper"
require "test_helpers/listener_test_helper"

# The preflight is the only place that decides whether the gem does anything at
# all, so every branch is tested for two things: the verdict, and the message the
# user gets. A silent wrong verdict is the failure mode we care about most.
class PreflightTest < Minitest::Test
  include ListenNotifyTestWaiting

  PREFLIGHT = SolidQueue::ListenNotify::Preflight

  FUNCTION_DEFINITION = <<~SQL
    CREATE OR REPLACE FUNCTION solid_queue_listen_notify_ready() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_notify('solid_queue_ready', NEW.queue_name);
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
  SQL

  # Doubles ---------------------------------------------------------------------

  # Stands in for pg's PG::Connection. The only thing the preflight asks of it is
  # whether a notification came back.
  class FakeRawConnection
    attr_reader :waits

    def initialize(delivered: true)
      @delivered = delivered
      @waits = []
    end

    def wait_for_notify(timeout = nil)
      @waits << timeout
      @delivered ? "solid_queue_ready" : nil
    end
  end

  # Stands in for an ActiveRecord PostgreSQL adapter connection.
  class FakeConnection
    attr_reader :raw_connection, :disconnects

    def initialize(raw_connection: FakeRawConnection.new, backend_pids: [ "10", "10" ])
      @raw_connection = raw_connection
      @backend_pids = backend_pids.dup
      @executed = []
      @disconnects = 0
    end

    def execute(sql, _name = nil)
      @executed << sql
      nil
    end

    def select_value(_sql)
      @backend_pids.shift
    end

    def quote(value)
      "'#{value}'"
    end

    def quote_column_name(name)
      %("#{name}")
    end

    def disconnect!
      @disconnects += 1
    end

    def executed
      @executed.dup
    end
  end

  class FakeInstaller
    attr_reader :installs

    def initialize(installed: true, definition: FUNCTION_DEFINITION, install_error: nil)
      @installed = installed
      @definition = definition
      @install_error = install_error
      @installs = 0
    end

    def installed?
      @installed
    end

    def install!
      @installs += 1
      raise @install_error if @install_error

      @installed = true
    end

    def function_definition
      @definition
    end
  end

  class FakeProvider
    attr_reader :calls

    def initialize(connection)
      @connection = connection
      @calls = 0
    end

    def call
      @calls += 1
      @connection
    end
  end

  def setup
    SolidQueue::ListenNotify.reset!
    @adapter_calls = 0
    @pooled_calls = 0
  end

  def teardown
    SolidQueue::ListenNotify.reset!
  end

  # Steps -----------------------------------------------------------------------

  def test_a_disabled_gem_stops_before_touching_the_database
    result = nil

    with_listen_notify_config(enabled: false) do
      result = build_preflight.run
    end

    refute result.operational?
    assert_equal :disabled, result.reason
    assert_equal 0, @adapter_calls, "a disabled gem must not look at the database at all"
    assert_equal 0, @pooled_calls
  end

  def test_a_non_postgres_adapter_is_reported_with_a_loud_banner
    result = nil
    log = capture_listen_notify_log { result = build_preflight(adapter: "sqlite3").run }

    refute result.operational?
    assert_equal :unsupported_adapter, result.reason
    assert_equal "sqlite3", result.details[:adapter]
    assert_equal 0, @pooled_calls, "the adapter check must not hold a connection"

    assert_includes log, "WARN"
    assert_includes log, "=" * 78
    assert_includes log, "solid_queue-listen_notify requires PostgreSQL. Detected adapter: sqlite3."
    assert_includes log, "The gem is INACTIVE"
    assert_includes log, "switch the queue database to PostgreSQL"
  end

  def test_a_postgres_adapter_whose_raw_connection_cannot_listen_is_unsupported_too
    connection = FakeConnection.new(raw_connection: Object.new)
    result = nil
    log = capture_listen_notify_log { result = build_preflight(connection: connection).run }

    refute result.operational?
    assert_equal :unsupported_adapter, result.reason
    assert_includes log, "solid_queue-listen_notify requires PostgreSQL"
  end

  def test_a_missing_trigger_with_auto_install_disabled_is_reported_with_the_exact_fix
    installer = FakeInstaller.new(installed: false)
    result = nil
    log = nil

    with_listen_notify_config(auto_install_trigger: false) do
      log = capture_listen_notify_log { result = build_preflight(installer: installer).run }
    end

    refute result.operational?
    assert_equal :trigger_missing, result.reason
    assert_equal 0, installer.installs, "auto_install_trigger was explicitly disabled"

    assert_includes log, "WARN"
    assert_includes log, "bin/rails generate solid_queue:listen_notify:install --database queue && bin/rails db:migrate"
    assert_includes log, "auto_install_trigger"
  end

  def test_a_missing_trigger_is_installed_by_default_and_the_preflight_passes
    installer = FakeInstaller.new(installed: false)

    result = build_preflight(installer: installer).run

    assert result.operational?
    assert_equal 1, installer.installs, "auto_install_trigger is on by default"
  end

  def test_an_install_that_is_not_allowed_degrades_to_a_missing_trigger
    installer = FakeInstaller.new(installed: false, install_error: RuntimeError.new("permission denied for table solid_queue_ready_executions"))
    result = nil
    log = nil

    with_listen_notify_config(auto_install_trigger: true) do
      log = capture_listen_notify_log { result = build_preflight(installer: installer).run }
    end

    refute result.operational?
    assert_equal :trigger_missing, result.reason
    assert_equal 1, installer.installs
    assert_includes log, "permission denied"
    assert_includes log, "bin/rails generate solid_queue:listen_notify:install"
  end

  def test_a_trigger_left_over_from_another_channel_is_a_mismatch
    installer = FakeInstaller.new(definition: FUNCTION_DEFINITION.sub("solid_queue_ready", "some_other_channel"))
    result = nil
    log = capture_listen_notify_log { result = build_preflight(installer: installer).run }

    refute result.operational?
    assert_equal :channel_mismatch, result.reason
    assert_equal "solid_queue_ready", result.details[:channel]
    assert_includes log, "does not notify on the"
    assert_includes log, "Re-run the installer"
  end

  def test_a_missing_function_definition_counts_as_a_mismatch
    result = nil
    capture_listen_notify_log { result = build_preflight(installer: FakeInstaller.new(definition: nil)).run }

    refute result.operational?
    assert_equal :channel_mismatch, result.reason
  end

  # The drift check used to ask whether the channel appeared ANYWHERE in the
  # function source. The function is called solid_queue_listen_notify_ready, so
  # every one of these channel names is a substring of the source no matter what
  # the trigger actually notifies — the check silently passed for a trigger
  # pointing somewhere else entirely.
  %w[ready notify listen solid queue solid_queue_listen_notify_ready].each do |channel|
    define_method(:"test_a_channel_named_#{channel}_is_not_matched_by_the_functions_own_name") do
      installer = FakeInstaller.new(definition: FUNCTION_DEFINITION)
      result = nil

      with_listen_notify_config(channel: channel) do
        capture_listen_notify_log { result = build_preflight(channel: channel, installer: installer).run }
      end

      refute result.operational?,
        "a trigger notifying 'solid_queue_ready' was accepted as notifying #{channel.inspect}"
      assert_equal :channel_mismatch, result.reason
    end
  end

  def test_the_exact_notify_call_is_what_makes_the_channel_match
    # pg_get_functiondef gives the body back verbatim, quote doubling included.
    installer = FakeInstaller.new(definition: FUNCTION_DEFINITION.sub("solid_queue_ready", "it''s_here"))
    result = nil

    with_listen_notify_config(channel: "it's_here") do
      result = build_preflight(channel: "it's_here", installer: installer).run
    end

    assert result.operational?, "pg_get_functiondef doubles an embedded quote, and so must the check"
  end

  # Channel length --------------------------------------------------------------

  def test_a_channel_over_63_bytes_is_refused_before_anything_touches_the_database
    result = nil
    log = nil

    with_listen_notify_config(channel: "a" * 64) do
      log = capture_listen_notify_log { result = build_preflight(channel: "a" * 64).run }
    end

    refute result.operational?
    assert_equal :invalid_channel, result.reason
    assert_equal 64, result.details[:bytesize]
    assert_equal 0, @adapter_calls, "an unusable channel is a configuration error, not a database question"
    assert_equal 0, @pooled_calls

    assert_includes log, "ERROR"
    assert_includes log, "=" * 78
    assert_includes log, "not a channel name"
    assert_includes log, "channel name too long"
    assert_includes log, "every enqueue"
    assert_includes log, PREFLIGHT::INSTALL_COMMAND
  end

  def test_a_channel_of_exactly_63_bytes_is_accepted
    result = nil

    with_listen_notify_config(channel: "a" * 63) do
      result = build_preflight(channel: "a" * 63, installer: FakeInstaller.new(definition: "pg_notify('#{"a" * 63}', NEW.queue_name)")).run
    end

    assert result.operational?
  end

  def test_an_empty_channel_is_refused_too
    result = nil

    with_listen_notify_config(channel: "") do
      capture_listen_notify_log { result = build_preflight(channel: "").run }
    end

    assert_equal :invalid_channel, result.reason
  end

  def test_a_disabled_gem_does_not_complain_about_its_channel
    result = nil

    with_listen_notify_config(enabled: false, channel: "a" * 64) do
      result = build_preflight(channel: "a" * 64).run
    end

    assert_equal :disabled, result.reason, "a gem that is off has no channel to be wrong about"
  end

  # Self-test -------------------------------------------------------------------

  # The self-test is only worth its two seconds if it exercises the REAL path:
  # LISTEN on the connection the listener will use, NOTIFY from the pooled
  # connection the trigger will fire on. Doing both halves on one connection
  # proved only that Postgres delivers a session its own notifications, and was
  # blind to a listen_database pointing at the wrong database.
  def test_a_passing_self_test_makes_the_gem_operational
    provider_connection = FakeConnection.new
    pooled_connection = FakeConnection.new
    provider = FakeProvider.new(provider_connection)
    result = build_preflight(connection: pooled_connection, provider: provider).run

    assert result.operational?
    assert_nil result.reason
    assert_equal 1, provider.calls
    assert_includes provider_connection.executed, %(LISTEN "solid_queue_ready")
    refute_includes provider_connection.executed, %(NOTIFY "solid_queue_ready", 'preflight'),
      "notifying itself would prove nothing about the queue database reaching the listener"
    assert_includes pooled_connection.executed, %(NOTIFY "solid_queue_ready", 'preflight'),
      "the NOTIFY has to come from the queue database, where the trigger runs"
  end

  def test_the_notify_is_sent_after_the_listen_so_it_cannot_be_missed
    provider_connection = FakeConnection.new
    pooled_connection = FakeConnection.new
    ordering = []
    provider_connection.stubs(:execute).with { |sql| ordering << [ :listen_connection, sql ]; true }
    pooled_connection.stubs(:execute).with { |sql| ordering << [ :pooled_connection, sql ]; true }

    build_preflight(connection: pooled_connection, provider: FakeProvider.new(provider_connection)).run

    listened = ordering.index { |where, sql| where == :listen_connection && sql.start_with?("LISTEN") }
    notified = ordering.index { |where, sql| where == :pooled_connection && sql.start_with?("NOTIFY") }

    assert listened, "no LISTEN was issued"
    assert notified, "no NOTIFY was issued"
    assert_operator listened, :<, notified
  end

  def test_the_self_test_connection_is_always_disconnected
    provider_connection = FakeConnection.new
    build_preflight(provider: FakeProvider.new(provider_connection)).run

    assert_includes provider_connection.executed, %(UNLISTEN "solid_queue_ready")
    assert_equal 1, provider_connection.disconnects, "nobody else can close a pool-removed connection"
  end

  def test_the_self_test_connection_is_disconnected_even_when_the_test_fails
    provider_connection = FakeConnection.new(raw_connection: FakeRawConnection.new(delivered: false))
    capture_listen_notify_log { build_preflight(provider: FakeProvider.new(provider_connection)).run }

    assert_equal 1, provider_connection.disconnects
  end

  def test_an_undelivered_notification_names_pgbouncer_and_the_way_out
    provider_connection = FakeConnection.new(raw_connection: FakeRawConnection.new(delivered: false))
    result = nil
    log = capture_listen_notify_log { result = build_preflight(provider: FakeProvider.new(provider_connection)).run }

    refute result.operational?
    assert_equal :self_test_failed, result.reason
    assert_equal false, result.details[:backend_pid_changed]

    assert_includes log, "ERROR"
    assert_includes log, "SELF-TEST FAILED"
    assert_includes log, "PgBouncer"
    assert_includes log, "transaction-mode connection pooler"
    assert_includes log, "`SolidQueue::ListenNotify.listen_database`"
    refute_includes log, "Backend PID changed"
  end

  # The self-test now spans two connections, so it fails for a second reason
  # besides a pooler: a listen_database that reaches a real Postgres which is not
  # the queue database. The banner has to name that, or the user is sent hunting
  # for a PgBouncer they do not have.
  def test_the_self_test_banner_names_a_misdirected_listen_database
    provider_connection = FakeConnection.new(raw_connection: FakeRawConnection.new(delivered: false))
    log = capture_listen_notify_log { build_preflight(provider: FakeProvider.new(provider_connection)).run }

    assert_includes log, "If `listen_database` is ALREADY set"
    assert_includes log, "THE SAME database as the queue"
  end

  def test_differing_backend_pids_add_the_pooler_heuristic
    connection = FakeConnection.new(backend_pids: [ "10", "77" ])
    provider_connection = FakeConnection.new(raw_connection: FakeRawConnection.new(delivered: false))
    result = nil
    log = capture_listen_notify_log do
      result = build_preflight(connection: connection, provider: FakeProvider.new(provider_connection)).run
    end

    assert_equal :self_test_failed, result.reason
    assert_equal true, result.details[:backend_pid_changed]
    assert_includes log, "Backend PID changed between consecutive statements"
    assert_includes log, "certainly behind a transaction-mode pooler"
  end

  # Failure containment ---------------------------------------------------------

  def test_a_step_that_raises_never_propagates
    preflight = PREFLIGHT.new(adapter_name: -> { raise Errno::ECONNREFUSED, "the database is down" })
    result = nil

    assert_silent { result = preflight.run }

    refute result.operational?
    assert_equal :error, result.reason
    assert_equal "Errno::ECONNREFUSED", result.details[:error]
    assert_includes result.details[:message], "the database is down"
  end

  def test_a_connection_provider_that_is_not_configured_never_propagates
    provider = -> { raise NotImplementedError, "no connection provider" }
    result = build_preflight(provider: provider).run

    refute result.operational?
    assert_equal :error, result.reason
    assert_equal "NotImplementedError", result.details[:error]
  end

  def test_a_failing_logger_does_not_take_the_preflight_down
    broken_logger = Object.new
    def broken_logger.warn(*) = raise(IOError, "log device closed")

    result = PREFLIGHT.new(adapter_name: -> { "sqlite3" }, logger: broken_logger).run

    refute result.operational?
    assert_equal :unsupported_adapter, result.reason
  end

  # Instrumentation -------------------------------------------------------------

  def test_every_run_instruments_exactly_one_preflight_event
    events = capture_listen_notify_events do
      capture_listen_notify_log do
        build_preflight.run
        build_preflight(adapter: "mysql2").run
        PREFLIGHT.new(adapter_name: -> { raise "boom" }).run
      end
    end

    preflights = events_named(events, "preflight")

    assert_equal 3, preflights.size
    assert_equal [ true, false, false ], preflights.map { |event| event.payload[:operational] }
    assert_equal [ nil, :unsupported_adapter, :error ], preflights.map { |event| event.payload[:reason] }
    assert_equal [ "solid_queue_ready" ], preflights.map { |event| event.payload[:channel] }.uniq
  end

  # Memoization (through the module) ---------------------------------------------

  def test_operational_runs_the_preflight_once_per_process
    fake = CountingPreflight.new(true)
    PREFLIGHT.stubs(:new).returns(fake)

    assert SolidQueue::ListenNotify.operational?
    assert SolidQueue::ListenNotify.operational?

    assert_equal 1, fake.runs
  end

  def test_reset_forces_the_preflight_to_run_again
    fake = CountingPreflight.new(false)
    PREFLIGHT.stubs(:new).returns(fake)

    refute SolidQueue::ListenNotify.operational?
    SolidQueue::ListenNotify.reset!

    refute SolidQueue::ListenNotify.operational?
    assert_equal 2, fake.runs
  end

  def test_a_verdict_reached_in_another_process_is_not_reused
    fake = CountingPreflight.new(true)
    PREFLIGHT.stubs(:new).returns(fake)

    assert SolidQueue::ListenNotify.operational?

    child_pid = Process.pid + 1
    Process.stubs(:pid).returns(child_pid)

    assert SolidQueue::ListenNotify.operational?
    assert_equal 2, fake.runs, "a forked child gets its own connections, so it needs its own verdict"
  ensure
    Process.unstub(:pid)
  end

  class CountingPreflight
    attr_reader :runs

    def initialize(operational)
      @operational = operational
      @runs = 0
    end

    def run
      @runs += 1
      SolidQueue::ListenNotify::Preflight::Result.new(operational: @operational)
    end
  end

  private
    def build_preflight(adapter: "postgresql", connection: FakeConnection.new, installer: FakeInstaller.new,
                        provider: FakeProvider.new(FakeConnection.new), **options)
      PREFLIGHT.new(
        adapter_name: -> { @adapter_calls += 1; adapter },
        with_connection: ->(&block) { @pooled_calls += 1; block.call(connection) },
        connection_provider: provider,
        trigger_installer: ->(_connection) { installer },
        self_test_timeout: 0.01,
        **options
      )
    end
end

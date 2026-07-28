# frozen_string_literal: true

require "test_helper"
require "erb"
require "active_record"
require "solid_queue/listen_notify/trigger_installer"

class TriggerInstallerSqlTest < Minitest::Test
  INSTALLER = SolidQueue::ListenNotify::TriggerInstaller

  PG_14 = 14_00_00
  PG_13 = 13_00_13

  # Enough of an Active Record connection for the installer, which only quotes,
  # executes and selects.
  class FakeConnection
    attr_reader :executed, :selected
    attr_accessor :database_version, :select_values

    def initialize(database_version: PG_14, select_values: [])
      @database_version = database_version
      @select_values = select_values
      @executed = []
      @selected = []
    end

    def quote(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end

    def execute(sql)
      @executed << sql
      nil
    end

    def select_value(sql)
      @selected << sql
      @select_values.shift
    end
  end

  def setup
    @connection = FakeConnection.new
    @installer = INSTALLER.new(connection: @connection)
  end

  # -- Function SQL ---------------------------------------------------------

  def test_function_sql_notifies_the_configured_channel
    sql = @installer.function_sql

    assert_includes sql, "CREATE OR REPLACE FUNCTION #{INSTALLER::FUNCTION_NAME}() RETURNS trigger"
    assert_includes sql, "PERFORM pg_notify('solid_queue_ready', NEW.queue_name);"
    assert_includes sql, "RETURN NULL;"
    assert_includes sql, "LANGUAGE plpgsql"
  end

  def test_function_sql_quotes_the_channel
    installer = INSTALLER.new(connection: @connection, channel: "it's_here")

    assert_includes installer.function_sql, "pg_notify('it''s_here', NEW.queue_name)"
  end

  def test_channel_defaults_to_the_configured_one
    with_listen_notify_config(channel: "custom_channel") do
      assert_includes INSTALLER.new(connection: @connection).function_sql, "pg_notify('custom_channel'"
    end
  end

  # -- Trigger SQL ----------------------------------------------------------

  def test_create_trigger_sql_targets_the_ready_executions_table
    sql = @installer.create_trigger_sql(replace: false)

    assert_includes sql, "CREATE TRIGGER #{INSTALLER::TRIGGER_NAME}"
    refute_includes sql, "OR REPLACE"
    assert_includes sql, "AFTER INSERT ON #{INSTALLER::TABLE_NAME}"
    assert_includes sql, "FOR EACH ROW EXECUTE FUNCTION #{INSTALLER::FUNCTION_NAME}();"
  end

  def test_create_trigger_sql_can_replace
    assert_includes @installer.create_trigger_sql(replace: true), "CREATE OR REPLACE TRIGGER #{INSTALLER::TRIGGER_NAME}"
  end

  # -- install! -------------------------------------------------------------

  def test_install_on_postgres_14_replaces_the_trigger_in_place
    @installer.install!

    assert_equal 2, @connection.executed.size
    assert_includes @connection.executed[0], "CREATE OR REPLACE FUNCTION"
    assert_includes @connection.executed[1], "CREATE OR REPLACE TRIGGER"
    refute(@connection.executed.any? { |sql| sql.include?("DROP TRIGGER") })
  end

  def test_install_before_postgres_14_drops_and_recreates_the_trigger
    @connection.database_version = PG_13
    @installer.install!

    assert_equal 3, @connection.executed.size
    assert_includes @connection.executed[0], "CREATE OR REPLACE FUNCTION"
    assert_equal @installer.drop_trigger_sql, @connection.executed[1]
    assert_includes @connection.executed[2], "CREATE TRIGGER #{INSTALLER::TRIGGER_NAME}"
    refute_includes @connection.executed[2], "OR REPLACE"
  end

  def test_replace_path_boundary_is_postgres_14_0
    @connection.database_version = PG_14 - 1
    @installer.install!

    assert_equal 3, @connection.executed.size, "13.99 must take the drop-and-create path"
  end

  def test_install_instruments_the_event
    events = capture_events("install_trigger.solid_queue_listen_notify") { @installer.install! }

    assert_equal 1, events.size
    assert_equal "solid_queue_ready", events.first.payload[:channel]
    assert_equal PG_14, events.first.payload[:database_version]
  end

  def test_install_is_idempotent_by_construction
    @installer.install!
    first = @connection.executed.dup
    @installer.install!

    assert_equal first, @connection.executed.drop(first.size)
  end

  # -- Channel length -------------------------------------------------------
  #
  # Postgres caps identifiers at 63 bytes. LISTEN/NOTIFY take the channel as an
  # identifier and truncate it SILENTLY, so the preflight's self-test would pass;
  # pg_notify() takes it as text and raises "channel name too long" — from inside
  # the trigger, which means every INSERT into solid_queue_ready_executions, i.e.
  # every enqueue in the application, would fail. Refusing to install is the only
  # place that can be caught before production.

  def test_a_channel_over_63_bytes_is_refused
    installer = INSTALLER.new(connection: @connection, channel: "a" * 64)

    error = assert_raises(ArgumentError) { installer.install! }

    assert_includes error.message, "between 1 and 63 bytes"
    assert_includes error.message, "64 bytes"
    assert_empty @connection.executed, "nothing may reach the database once the channel is known to be bad"
  end

  def test_the_limit_is_counted_in_BYTES_not_characters
    # 32 two-byte characters is 32 characters and 64 bytes.
    installer = INSTALLER.new(connection: @connection, channel: "é" * 32)

    assert_raises(ArgumentError) { installer.install! }
    assert INSTALLER.channel_valid?("é" * 31)
  end

  def test_a_channel_of_exactly_63_bytes_installs
    INSTALLER.new(connection: @connection, channel: "a" * 63).install!

    assert_equal 2, @connection.executed.size
  end

  def test_an_empty_channel_is_refused
    [ "", nil ].each do |channel|
      assert_raises(ArgumentError) { INSTALLER.new(connection: @connection, channel: channel).install! }
      refute INSTALLER.channel_valid?(channel)
    end
  end

  # -- uninstall! -----------------------------------------------------------

  def test_uninstall_drops_the_trigger_and_the_function
    @installer.uninstall!

    assert_equal 2, @connection.executed.size
    assert_includes @connection.executed[0], "DROP TRIGGER IF EXISTS #{INSTALLER::TRIGGER_NAME} ON #{INSTALLER::TABLE_NAME}"
    assert_includes @connection.executed[1], "DROP FUNCTION IF EXISTS #{INSTALLER::FUNCTION_NAME}()"
  end

  # -- installed? / function_definition -------------------------------------

  # Resolving the table with to_regclass is what makes this schema-aware: it
  # goes through the connection's search_path exactly as the INSERTs the trigger
  # fires on do. Matching pg_class on relname alone reported "installed" for a
  # trigger sitting on a different schema's copy of the table.
  def test_installed_query_resolves_the_table_through_the_search_path
    @connection.select_values = [ true ]

    assert @installer.installed?

    sql = @connection.selected.first
    assert_includes sql, "FROM pg_trigger"
    assert_includes sql, "t.tgrelid = to_regclass('#{INSTALLER::TABLE_NAME}')"
    assert_includes sql, "t.tgname = '#{INSTALLER::TRIGGER_NAME}'"
    assert_includes sql, "NOT t.tgisinternal"
    refute_includes sql, "relname", "matching on the bare relation name is what made this cross-schema"
  end

  def test_installed_casts_the_result
    { true => true, "t" => true, false => false, nil => false }.each do |value, expected|
      @connection.select_values = [ value ]

      assert_equal expected, @installer.installed?, "expected #{value.inspect} to read as #{expected}"
    end
  end

  def test_function_definition_returns_the_source_or_nil
    @connection.select_values = [ "CREATE OR REPLACE FUNCTION ..." ]

    assert_equal "CREATE OR REPLACE FUNCTION ...", @installer.function_definition
    assert_includes @connection.selected.first, "pg_get_functiondef"
    assert_includes @connection.selected.first, "p.proname = '#{INSTALLER::FUNCTION_NAME}'"

    @connection.select_values = [ nil ]
    assert_nil @installer.function_definition
  end

  # -- Migration template stays in sync -------------------------------------

  TEMPLATE_PATH = File.expand_path(
    "../../lib/generators/solid_queue/listen_notify/install/templates/install_solid_queue_listen_notify_trigger.rb.erb",
    __dir__
  )

  GENERATOR_PATH = File.expand_path(
    "../../lib/generators/solid_queue/listen_notify/install/install_generator.rb", __dir__
  )

  # Stands in for the generator's binding when rendering the template.
  class TemplateContext
    def initialize(channel)
      @channel = channel
    end

    def quoted_channel
      "'#{@channel}'"
    end

    def render(template)
      ERB.new(template, trim_mode: "-").result(binding)
    end
  end

  def test_template_renders_a_self_contained_migration
    rendered = render_template

    assert_includes rendered,
      "class InstallSolidQueueListenNotifyTrigger < ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]"
    refute_includes rendered, "SolidQueue::ListenNotify", "the migration must not reference the gem"
    assert_includes rendered, "PERFORM pg_notify('solid_queue_ready', NEW.queue_name);"
    assert_includes rendered, "RETURN NULL;"
    assert_includes rendered, "AFTER INSERT ON #{INSTALLER::TABLE_NAME}"
    assert_includes rendered, "FOR EACH ROW"
    assert_includes rendered, "connection.database_version >= 14_00_00"
    assert_equal 14_00_00, INSTALLER::REPLACE_TRIGGER_MINIMUM_VERSION
  end

  def test_template_sql_matches_the_installer
    rendered = squish(render_template)

    [ @installer.function_sql,
      @installer.create_trigger_sql(replace: true),
      @installer.create_trigger_sql(replace: false),
      @installer.drop_trigger_sql,
      @installer.drop_function_sql ].each do |sql|
      assert_includes rendered, squish(sql), "migration template is out of sync with TriggerInstaller"
    end
  end

  def test_template_down_drops_both_the_trigger_and_the_function
    down = squish(render_template.split(/^  def down$/, 2).last.to_s)

    assert_includes down, squish(@installer.drop_trigger_sql)
    assert_includes down, squish(@installer.drop_function_sql)
  end

  def test_generator_renders_this_template
    generator = File.read(GENERATOR_PATH)

    assert_includes generator, File.basename(TEMPLATE_PATH)
    assert_includes generator, "def quoted_channel"
    assert_includes generator, "install_solid_queue_listen_notify_trigger.rb\""
  end

  private
    def render_template
      TemplateContext.new(SolidQueue::ListenNotify.channel).render(File.read(TEMPLATE_PATH))
    end

    def squish(sql)
      sql.gsub(/\s+/, " ").strip
    end

    def capture_events(name)
      events = []
      subscriber = ActiveSupport::Notifications.subscribe(name) { |*args| events << ActiveSupport::Notifications::Event.new(*args) }
      yield
      events
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end

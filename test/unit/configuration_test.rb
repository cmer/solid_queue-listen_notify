# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  ENV_KEY = "SOLID_QUEUE_LISTEN_NOTIFY_ENABLED"

  CONFIG_KEYS = %i[
    enabled channel fallback_polling_interval listen_database auto_install_trigger
    wake_saturated_workers wait_timeout keepalive_interval reconnect_wait
    connection_errors_reporting_threshold application_name connection_provider
  ].freeze

  def test_defaults
    config = SolidQueue::ListenNotify

    assert_equal "solid_queue_ready", config.channel
    assert_equal 10.seconds, config.fallback_polling_interval
    assert_nil config.listen_database
    assert_equal true, config.auto_install_trigger
    assert_equal false, config.wake_saturated_workers
    assert_equal 1.second, config.wait_timeout
    assert_equal 10.seconds, config.keepalive_interval
    assert_equal 5.seconds, config.reconnect_wait
    assert_equal 6, config.connection_errors_reporting_threshold
  end

  def test_enabled_defaults_to_true_when_the_env_variable_is_unset
    assert_equal true, enabled_with_env(nil)
  end

  def test_the_env_variable_kill_switch
    refute enabled_with_env("false")
  end

  def test_the_env_variable_set_to_true
    assert enabled_with_env("true")
  end

  def test_only_the_literal_string_false_disables_the_gem
    # Matches the documented behavior: "0" and anything else leave it enabled.
    assert enabled_with_env("0")
    assert enabled_with_env("no")
    assert enabled_with_env("")
  end

  def test_enabled_predicate_follows_the_accessor
    with_listen_notify_config(enabled: false) do
      refute SolidQueue::ListenNotify.enabled?
    end

    with_listen_notify_config(enabled: true) do
      assert SolidQueue::ListenNotify.enabled?
    end
  end

  def test_configuration_is_writable
    with_listen_notify_config(channel: "other_channel", fallback_polling_interval: nil) do
      assert_equal "other_channel", SolidQueue::ListenNotify.channel
      assert_nil SolidQueue::ListenNotify.fallback_polling_interval
    end

    assert_equal "solid_queue_ready", SolidQueue::ListenNotify.channel
    assert_equal 10.seconds, SolidQueue::ListenNotify.fallback_polling_interval
  end

  def test_application_name_defaults_to_the_current_pid
    assert_equal "solid_queue-listen_notify [#{Process.pid}]", SolidQueue::ListenNotify.application_name
  end

  def test_application_name_reads_the_pid_at_call_time
    Process.stubs(:pid).returns(4242)

    assert_equal "solid_queue-listen_notify [4242]", SolidQueue::ListenNotify.application_name
  end

  def test_application_name_honors_an_override
    with_listen_notify_config(application_name: "custom") do
      assert_equal "custom", SolidQueue::ListenNotify.application_name
    end

    assert_equal "solid_queue-listen_notify [#{Process.pid}]", SolidQueue::ListenNotify.application_name
  end

  def test_instrument_emits_a_namespaced_event
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("start.solid_queue_listen_notify") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    result = SolidQueue::ListenNotify.instrument(:start, channel: "solid_queue_ready") { :returned }

    assert_equal :returned, result
    assert_equal 1, events.size
    assert_equal "start.solid_queue_listen_notify", events.first.name
    assert_equal "solid_queue_ready", events.first.payload[:channel]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_instrument_works_without_a_block
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("notify.solid_queue_listen_notify") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    SolidQueue::ListenNotify.instrument(:notify, queue_name: "background")

    assert_equal [ "background" ], events.map { |event| event.payload[:queue_name] }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # The unit suite runs without ActiveRecord, Solid Queue or pg loaded, which is
  # the harshest version of "the setup is broken": every entry point still has to
  # come back quietly, having changed nothing.
  def test_the_public_api_is_inert_when_nothing_is_available
    with_listen_notify_config(enabled: false) do
      assert_equal false, SolidQueue::ListenNotify.operational?
      assert_nil SolidQueue::ListenNotify.register(Object.new)
      assert_nil SolidQueue::ListenNotify.deregister(Object.new)
      assert_nil SolidQueue::ListenNotify.after_fork
      assert_nil SolidQueue::ListenNotify.reset!
    end

    refute SolidQueue::ListenNotify::Registry.instantiated?
  ensure
    SolidQueue::ListenNotify.reset!
  end

  def test_a_default_connection_provider_is_configured
    assert_respond_to SolidQueue::ListenNotify.connection_provider, :call
  end

  # The guard for the whole design: every reference to Rails, ActiveRecord and pg
  # is resolved inside a method body, so requiring the gem pulls in none of them.
  # Checked in a subprocess because this one has railties loaded through
  # minitest's plugin discovery.
  def test_requiring_the_gem_loads_neither_rails_nor_active_record_nor_pg
    script = <<~RUBY
      require "solid_queue/listen_notify"
      print [ defined?(::Rails), defined?(::ActiveRecord), defined?(::PG) ].compact.inspect
    RUBY

    output = IO.popen([ Gem.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script ], &:read)

    assert_predicate $?, :success?, "requiring the gem on its own failed"
    assert_equal "[]", output, "requiring the gem must not load Rails, ActiveRecord or pg"
  end

  private
    # `enabled`'s default is computed when the module is loaded, so the only
    # honest way to exercise the env kill switch is to reload it.
    def enabled_with_env(value)
      previous_env = ENV[ENV_KEY]
      previous_config = CONFIG_KEYS.to_h { |key| [ key, SolidQueue::ListenNotify.class_variable_get(:"@@#{key}") ] }

      ENV[ENV_KEY] = value
      load File.expand_path("../../lib/solid_queue/listen_notify.rb", __dir__)
      SolidQueue::ListenNotify.enabled?
    ensure
      ENV[ENV_KEY] = previous_env
      previous_config.each { |key, previous| SolidQueue::ListenNotify.public_send(:"#{key}=", previous) }
    end
end

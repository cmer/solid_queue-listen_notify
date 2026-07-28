# frozen_string_literal: true

require "logger"
require "stringio"

# Shared by both tiers: the unit suite loads it without Rails, the integration
# suite loads it with a booted dummy app.
module ConfigTestHelper
  # Sets configuration for the duration of the block and restores the previous
  # values, reading them straight off the class variables so that lazily computed
  # readers (application_name) aren't frozen to their computed value.
  def with_listen_notify_config(**overrides)
    previous = overrides.keys.to_h { |key| [ key, SolidQueue::ListenNotify.class_variable_get(:"@@#{key}") ] }
    overrides.each { |key, value| SolidQueue::ListenNotify.public_send(:"#{key}=", value) }
    yield
  ensure
    previous.each { |key, value| SolidQueue::ListenNotify.public_send(:"#{key}=", value) }
  end

  # Captures everything the gem logs during the block and returns it as a string.
  # The gem resolves its logger on every call, so standing in for it here catches
  # the banners the preflight writes directly as well as anything a LogSubscriber
  # emits.
  def capture_listen_notify_log(level: Logger::DEBUG)
    output = StringIO.new
    logger = Logger.new(output)
    logger.level = level
    logger.formatter = ->(severity, _time, _progname, message) { "#{severity} #{message}\n" }

    SolidQueue::ListenNotify.stubs(:logger).returns(logger)
    yield logger

    output.string
  ensure
    SolidQueue::ListenNotify.unstub(:logger)
  end
end

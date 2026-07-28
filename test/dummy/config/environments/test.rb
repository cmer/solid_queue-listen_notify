# frozen_string_literal: true

require "fileutils"
require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = false

  config.consider_all_requests_local = true
  config.cache_store = :null_store

  config.active_support.deprecation = :stderr
  config.active_support.disallowed_deprecation = :raise
  config.active_support.disallowed_deprecation_warnings = []

  # The integration helper prepares both databases itself, from the schema
  # files, before any test runs.
  config.active_record.maintain_test_schema = false

  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Everything the workers and the gem log goes to log/test.log so that a failing
  # run has a transcript, without a test's output being drowned in it.
  FileUtils.mkdir_p(Rails.root.join("log"))
  config.logger = ActiveSupport::Logger.new(Rails.root.join("log/test.log"))
  config.log_level = :debug
  config.solid_queue.logger = config.logger

  config.solid_queue.on_thread_error = ->(exception) do
    Rails.logger.error("#{exception.class.name}: #{exception.message}\n#{(exception.backtrace || caller)&.join("\n")}")
  end

  # Keeps `worker.stop` from taking five seconds in every test that starts one.
  config.solid_queue.shutdown_timeout = 2.seconds
end

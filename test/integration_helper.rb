# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require "minitest"

require_relative "dummy/config/environment"
require "rails/test_help"
require "mocha/minitest"

require_relative "test_helpers/config_test_helper"
require_relative "test_helpers/integration_test_helper"

module IntegrationDatabase
  extend self

  # Both databases are created if missing and their schema is loaded on every
  # run. Reloading is cheap (the schema files are `force: :cascade` creates) and
  # it means a stale test database can never be the reason a run fails.
  def prepare!
    tasks = ActiveRecord::Tasks::DatabaseTasks

    # DatabaseTasks.create connects ActiveRecord::Base to the `postgres`
    # maintenance database to issue CREATE DATABASE and never puts it back — the
    # rake tasks re-establish afterwards, and so do we.
    original_db_config = ActiveRecord::Base.connection_db_config

    quietly do
      ActiveRecord::Base.configurations.configs_for(env_name: "test").each do |db_config|
        tasks.create(db_config)

        # Rails 8.0 renamed `with_temporary_connection_for_each` (7.1/7.2) to
        # `with_temporary_pool_for_each`. Both do what this needs: point
        # ActiveRecord::Base at the given database for the duration of the block
        # — which is what `load` of a schema file writes into — and put the
        # previous connection back afterwards. Neither yielded value is used.
        with_temporary_connection = tasks.respond_to?(:with_temporary_pool_for_each) ?
          :with_temporary_pool_for_each : :with_temporary_connection_for_each

        tasks.public_send(with_temporary_connection, env: "test", name: db_config.name) do
          tasks.load_schema(db_config, :ruby, tasks.schema_dump_path(db_config))
        end
      end
    end

    ActiveRecord::Base.establish_connection(original_db_config)
  end

  # Installed once for the whole run, right after the schema load that dropped
  # it along with the table. Tests that need it gone uninstall and reinstall it
  # around themselves.
  def install_trigger!
    SolidQueue::ListenNotify.with_queue_connection do |connection|
      SolidQueue::ListenNotify::TriggerInstaller.new(connection: connection).install!
    end
  end

  private
    # DatabaseTasks announces every create and every schema statement on stdout
    # unless VERBOSE says otherwise.
    def quietly
      previous, ENV["VERBOSE"] = ENV["VERBOSE"], "false"
      yield
    ensure
      ENV["VERBOSE"] = previous
    end
end

IntegrationDatabase.prepare!
IntegrationDatabase.install_trigger!

# Postgres delivers a NOTIFY when the sending transaction COMMITS. A transactional
# test never commits, so every one of these tests would be testing nothing.
class IntegrationTestCase < ActiveSupport::TestCase
  include ConfigTestHelper, IntegrationTestHelper

  self.use_transactional_tests = false

  setup do
    @_lifecycle_hooks = snapshot_lifecycle_hooks
    @_on_thread_error = SolidQueue.on_thread_error
    ActiveJob::QueueAdapters::SolidQueueAdapter.stopping = false

    reset_listen_notify!
    destroy_records
  end

  teardown do
    stop_workers
    reset_listen_notify!

    restore_lifecycle_hooks(@_lifecycle_hooks)
    SolidQueue.on_thread_error = @_on_thread_error
    ActiveJob::QueueAdapters::SolidQueueAdapter.stopping = false

    destroy_records
  end
end

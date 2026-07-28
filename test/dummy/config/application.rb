# frozen_string_literal: true

require_relative "boot"

# Three frameworks and no more: no action_pack, no action_mailer, no assets. The
# gem has no web layer to test, and a boot this small keeps the integration suite
# honest about what it actually depends on.
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"

# Deliberately explicit instead of Bundler.require, which would pull the whole
# development group (rubocop, debug, appraisal…) into every test process.
require "solid_queue"
require "solid_queue/listen_notify"

module Dummy
  class Application < Rails::Application
    # Set explicitly: Rails infers the root by walking up from here looking for a
    # config.ru, and this app has no rack entry point to find.
    config.root = File.expand_path("..", __dir__)

    config.load_defaults Rails::VERSION::STRING.to_f

    config.eager_load = false
    config.active_job.queue_adapter = :solid_queue

    # `config.solid_queue_listen_notify` is left at its defaults on purpose:
    # the integration tests configure the module directly so that each one can
    # state exactly which setting it depends on.
  end
end

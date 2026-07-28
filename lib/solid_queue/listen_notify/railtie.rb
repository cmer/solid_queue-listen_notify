# frozen_string_literal: true

require "rails/railtie"
require "active_support/fork_tracker"

require_relative "log_subscriber"

module SolidQueue
  module ListenNotify
    # A Railtie, not an Engine: this gem ships no app code and no migrations of
    # its own (the generator writes one into the host app instead).
    #
    # Everything here is wiring. The hooks go in inside on_load(:solid_queue) so
    # that they are installed whether Solid Queue loads before or after us, and
    # they are the documented lifecycle hooks — no part of this gem patches
    # Solid Queue.
    class Railtie < ::Rails::Railtie
      config.solid_queue_listen_notify = ActiveSupport::OrderedOptions.new

      initializer "solid_queue_listen_notify.config" do |app|
        ListenNotify.apply_configuration(app.config.solid_queue_listen_notify)
      end

      initializer "solid_queue_listen_notify.logger" do
        LogSubscriber.attach_to :solid_queue_listen_notify
      end

      initializer "solid_queue_listen_notify.hooks" do
        ActiveSupport.on_load(:solid_queue) do
          SolidQueue.on_worker_start { |worker| SolidQueue::ListenNotify.register(worker) }
          SolidQueue.on_worker_stop { |worker| SolidQueue::ListenNotify.deregister(worker) }
        end
      end

      initializer "solid_queue_listen_notify.fork_tracker" do
        # The listener's connection was removed from its pool, so ActiveRecord's
        # own post-fork cleanup cannot see it. This hook is the process-wide
        # backstop for the pid checks the registry and the listener already do.
        ActiveSupport::ForkTracker.after_fork do
          ListenNotify.after_fork
        end
      end
    end
  end
end

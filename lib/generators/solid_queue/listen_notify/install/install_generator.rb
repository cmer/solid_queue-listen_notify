# frozen_string_literal: true

require "rails/generators/active_record"
require "solid_queue/listen_notify"

module SolidQueue
  module ListenNotify
    module Generators
      class InstallGenerator < Rails::Generators::Base
        include ActiveRecord::Generators::Migration

        namespace "solid_queue:listen_notify:install"
        source_root File.expand_path("templates", __dir__)

        class_option :database, type: :string, aliases: %i[ --db ], default: "queue",
          desc: "The database that Solid Queue uses. Defaults to `queue`"

        # Generating a migration that cannot run is worse than refusing to
        # generate one: the failure would land on whoever runs db:migrate, or —
        # if the trigger installs at all — on every enqueue in production.
        def validate_channel
          return if SolidQueue::ListenNotify::TriggerInstaller.channel_valid?(channel)

          raise Thor::Error, SolidQueue::ListenNotify::TriggerInstaller.channel_error_message(channel)
        end

        def create_migration_file
          migration_template "install_solid_queue_listen_notify_trigger.rb.erb",
            File.join(db_migrate_path, "install_solid_queue_listen_notify_trigger.rb")
        end

        private
          def channel
            SolidQueue::ListenNotify.channel.to_s
          end

          # Baked into the migration at generation time so that the migration keeps
          # working after the gem is removed.
          def quoted_channel
            "'#{channel.gsub("'", "''")}'"
          end
      end
    end
  end
end

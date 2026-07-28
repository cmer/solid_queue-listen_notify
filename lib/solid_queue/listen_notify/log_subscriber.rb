# frozen_string_literal: true

require "active_support/log_subscriber"

require_relative "version"

module SolidQueue
  module ListenNotify
    # Same shape and formatting as SolidQueue::LogSubscriber, so that a log with
    # both in it reads as one stream. Deliberately quiet: the two events that
    # happen constantly (notify, keepalive) are debug-level, and the loud
    # multi-line banners are logged by the preflight itself rather than from
    # here, because they must come out even when nobody attached a subscriber.
    class LogSubscriber < ActiveSupport::LogSubscriber
      def preflight(event)
        attributes = event.payload.slice(:channel, :operational, :reason, :details)

        if event.payload[:operational]
          info formatted_event(event, action: "Preflight passed", **attributes)
        elsif event.payload[:reason] == :disabled
          debug formatted_event(event, action: "Preflight skipped", **attributes)
        else
          warn formatted_event(event, action: "Preflight failed – the gem is inactive", **attributes)
        end
      end

      # The event is `start_listener`, not `start`: ActiveSupport::Subscriber
      # reserves `start` and `finish` for the notifier protocol and silently
      # refuses to subscribe a method named either way.
      def start_listener(event)
        info formatted_event(event, action: "Started listener", **event.payload.slice(:pid, :channel))
      end

      def notify(event)
        debug formatted_event(event, action: "Notification", **event.payload.slice(:queue_name, :woken, :skipped_saturated))
      end

      def keepalive(event)
        debug formatted_event(event, action: "Keepalive", **event.payload.slice(:pid))
      end

      def reconnect(event)
        attributes = event.payload.slice(:error, :message, :consecutive_failures, :wait)

        if event.payload[:reported]
          error formatted_event(event, action: "Listener connection lost – reconnecting", **attributes)
        else
          warn formatted_event(event, action: "Listener connection lost – reconnecting", **attributes)
        end
      end

      def install_trigger(event)
        info formatted_event(event, action: "Installed notification trigger", **event.payload.slice(:channel, :database_version))
      end

      def fork_detected(event)
        warn formatted_event(event, action: "Fork detected – discarding the inherited listener", **event.payload.slice(:parent_pid, :pid))
      end

      def shutdown(event)
        attributes = event.payload.slice(:pid, :error, :message)

        if event.payload[:error]
          error formatted_event(event, action: "Listener died", **attributes)
        else
          info formatted_event(event, action: "Stopped listener", **attributes)
        end
      end

      # The same event covers both directions: raising an interval once
      # notifications are proven, and putting it back when the listener dies for
      # good and they stop being proven.
      def override_polling_interval(event)
        action = event.payload[:restored] ? "Restored polling interval" : "Raised polling interval"

        info formatted_event(event, action: action, **event.payload.slice(:worker_name, :from, :to))
      end

      private
        def formatted_event(event, action:, **attributes)
          "SolidQueue-ListenNotify-#{ListenNotify::VERSION} #{action} (#{event.duration.round(1)}ms)  #{formatted_attributes(**attributes)}"
        end

        def formatted_attributes(**attributes)
          attributes.map { |attr, value| "#{attr}: #{value.inspect}" }.join(", ")
        end

        # Same logger as everything else the gem says: Solid Queue's, with a
        # fallback that guarantees the warnings are never lost.
        def logger
          ListenNotify.logger
        end
    end
  end
end

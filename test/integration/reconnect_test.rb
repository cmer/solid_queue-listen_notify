# frozen_string_literal: true

require "integration_helper"

# A listener holds one connection open for the lifetime of the process, so it
# will outlive network blips, failovers and idle-session reapers. Killing its
# backend from another session is the closest thing to all of those.
class ReconnectTest < IntegrationTestCase
  test "the listener reconnects after its backend is terminated and keeps waking workers" do
    queue = unique_queue("reconnect")
    worker = start_worker(queues: queue, polling_interval: 60)
    wait_for_listen_notify_registration(worker)

    original_pids = wait_for_listener_backend
    assert_equal 1, original_pids.size

    events = Concurrent::Array.new
    subscriber = ActiveSupport::Notifications.subscribe("reconnect.solid_queue_listen_notify") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    terminate_listener_backends(original_pids)

    # Detection costs up to one wait_timeout, then the listener backs off for
    # reconnect_wait (5s by default) before trying again.
    wait_for(timeout: 15.seconds) { events.any? }
    new_pids = wait_for(timeout: 15.seconds) { (listener_backend_pids - original_pids).presence }

    assert_empty(new_pids & original_pids, "the listener kept using the terminated backend")
    assert_empty(listener_backend_pids & original_pids, "the terminated backend is still listed")

    enqueued_at = monotonic_now
    enqueue_result_job(queue, "reconnected")

    assert wait_for_job_result("reconnected", timeout: 3.seconds),
      "the worker was never woken after the listener reconnected"

    puts format("\n  post-reconnect wake latency: %.3fs", monotonic_now - enqueued_at)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end

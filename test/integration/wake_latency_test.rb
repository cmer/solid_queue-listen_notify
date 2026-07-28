# frozen_string_literal: true

require "integration_helper"

# The headline proof: a worker whose polling interval is a full minute picks a
# job up in well under a second. Polling cannot explain that; only the
# notification can.
class WakeLatencyTest < IntegrationTestCase
  POLLING_INTERVAL = 60

  test "a worker polling every 60 seconds runs a job in under three seconds" do
    queue = unique_queue("wake_latency")
    worker = start_worker(queues: queue, polling_interval: POLLING_INTERVAL)

    wait_for_listen_notify_registration(worker)
    wait_for_listener_backend

    # Whatever it costs to reach `perform_later` isn't latency the gem controls.
    enqueue_result_job(queue, "wake-latency")
    enqueued_at = monotonic_now

    assert wait_for_job_result("wake-latency", timeout: 3.seconds), "job was never run"
    latency = monotonic_now - enqueued_at

    assert_operator latency, :<, 3.0,
      "expected the job to run in under 3s, took #{latency.round(3)}s"

    # The interval is above the fallback (10s), so the gem must have left it
    # alone: polling genuinely could not have picked this job up.
    assert_equal POLLING_INTERVAL, worker.polling_interval

    puts format("\n  wake latency: %.3fs (polling_interval: %ds)", latency, POLLING_INTERVAL)
  end

  test "the notification names the queue the job was enqueued on" do
    queue = unique_queue("wake_latency_payload")
    worker = start_worker(queues: queue, polling_interval: POLLING_INTERVAL)

    wait_for_listen_notify_registration(worker)
    wait_for_listener_backend

    events = capture_listen_notify_events(:notify) do |captured|
      enqueue_result_job(queue, "payload")
      assert wait_for_job_result("payload", timeout: 3.seconds)
      wait_for(timeout: 3.seconds) { captured.any? }
    end

    event = events.find { |e| e.payload[:queue_name] == queue }
    assert event, "no notify event for #{queue}, saw #{events.map { |e| e.payload[:queue_name] }.inspect}"
    assert_equal 1, event.payload[:woken]
    assert_equal 0, event.payload[:skipped_saturated]
  end
end

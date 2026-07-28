# frozen_string_literal: true

require "integration_helper"

# Async mode runs every worker as a thread in one process. One LISTEN connection
# per worker would turn a gem that exists to REDUCE database load into one that
# adds a connection per worker, so the registry multiplexes: one connection, one
# listener thread, N workers, and each notification goes only to the workers
# whose queues match.
class AsyncMultiplexTest < IntegrationTestCase
  test "two workers share one listener connection and are woken selectively" do
    alpha = unique_queue("alpha_mux")
    beta = unique_queue("beta_mux")

    alpha_worker = start_worker(queues: alpha, polling_interval: 60)
    beta_worker = start_worker(queues: beta, polling_interval: 60)

    wait_for_listen_notify_registration(alpha_worker)
    wait_for_listen_notify_registration(beta_worker)

    pids = wait_for_listener_backend
    assert_equal 1, pids.size, "expected exactly one listener connection, found #{pids.inspect}"
    assert_equal 2, listen_notify_registry.workers.size

    events = capture_listen_notify_events(:notify) do |captured|
      enqueue_result_job(alpha, "alpha")
      assert wait_for_job_result("alpha", timeout: 3.seconds)
      wait_for(timeout: 3.seconds) { captured.any? { |event| event.payload[:queue_name] == alpha } }
    end

    alpha_event = events.find { |event| event.payload[:queue_name] == alpha }
    assert alpha_event, "no notification for #{alpha}"

    # One woken worker out of two registered: beta was ruled out by the queue
    # matcher, not by being saturated.
    assert_equal 1, alpha_event.payload[:woken]
    assert_equal 0, alpha_event.payload[:skipped_saturated]

    assert_empty events.select { |event| event.payload[:queue_name] == beta }
    assert_empty JobResult.where(queue_name: beta)

    # Still one connection after all that traffic.
    assert_equal pids, listener_backend_pids

    # Canary: the worker that was correctly NOT woken is still a working worker.
    enqueue_result_job(beta, "beta")
    assert wait_for_job_result("beta", timeout: 3.seconds)
  end

  test "the listener shuts down when the last worker deregisters" do
    worker = start_worker(queues: unique_queue("last_worker"), polling_interval: 60)
    wait_for_listen_notify_registration(worker)
    assert_equal 1, wait_for_listener_backend.size

    stop_workers

    assert_empty listen_notify_registry.workers
    assert_nil listen_notify_registry.listener
    wait_while_with_timeout(5.seconds) { listener_backend_pids.any? }
    assert_empty listener_backend_pids
  end
end

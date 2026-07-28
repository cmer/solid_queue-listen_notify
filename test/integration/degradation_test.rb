# frozen_string_literal: true

require "integration_helper"

# The safety property, and the one the gem is allowed to fail loudly on but never
# quietly: with the notification path broken, everything must fall back to stock
# Solid Queue. In particular the polling interval must be left exactly as the
# application configured it — a worker raised to 10s with nothing to wake it
# would be strictly worse than not installing the gem.
class DegradationTest < IntegrationTestCase
  test "with the trigger dropped, workers keep their own polling interval and still run jobs" do
    uninstall_trigger!
    SolidQueue::ListenNotify.reset!

    assert_not SolidQueue::ListenNotify.operational?

    queue = unique_queue("degraded")
    worker = start_worker(queues: queue, polling_interval: 1)

    # The fallback interval is 10s: an operational gem would have raised this.
    assert_equal 1, worker.polling_interval

    assert_empty listen_notify_registry.workers
    assert_nil listen_notify_registry.listener

    wait_while_with_timeout(5.seconds) { listener_backend_pids.any? }
    assert_empty listener_backend_pids

    enqueued_at = monotonic_now
    enqueue_result_job(queue, "degraded")

    assert wait_for_job_result("degraded", timeout: 5.seconds), "polling never picked the job up"
    latency = monotonic_now - enqueued_at

    assert_operator latency, :<, 3.0,
      "expected polling at 1s to pick the job up quickly, took #{latency.round(3)}s"

    puts format("\n  degraded (polling only) latency: %.3fs", latency)
  ensure
    install_trigger!
    SolidQueue::ListenNotify.reset!
  end

  test "the polling interval is only ever raised, never lowered" do
    queue = unique_queue("no_lowering")
    worker = start_worker(queues: queue, polling_interval: 60)
    wait_for_listen_notify_registration(worker)

    assert SolidQueue::ListenNotify.operational?
    assert_equal 60, worker.polling_interval
  end

  test "an operational gem raises a worker below the fallback interval up to it" do
    queue = unique_queue("raised")
    events = capture_listen_notify_events(:override_polling_interval) do
      worker = start_worker(queues: queue, polling_interval: 0.5)
      wait_for_listen_notify_registration(worker)

      assert_equal SolidQueue::ListenNotify.fallback_polling_interval.to_f, worker.polling_interval
    end

    assert_equal 0.5, events.last.payload[:from]
    assert_equal 10.0, events.last.payload[:to]
  end

  # The one failure this gem must never cause. The interval was raised on the
  # strength of a promise — notifications arrive — and a listener that dies for
  # good has broken it. Leaving the worker at 10 seconds with nothing to wake it
  # is strictly worse than never having installed the gem, so the promise is
  # withdrawn: intervals go back, the workers are woken so they re-read them, and
  # it is said out loud.
  test "a listener that dies for good puts every raised interval back" do
    queue = unique_queue("crashed")
    worker = start_worker(queues: queue, polling_interval: 0.5)
    wait_for_listen_notify_registration(worker)

    assert_equal 10.0, worker.polling_interval
    listener = listen_notify_registry.listener
    assert listener

    log = nil
    events = capture_listen_notify_events(:override_polling_interval, :shutdown) do
      log = capture_listen_notify_log do
        # Ruby prints the backtrace of a thread that dies with an exception, and
        # this test kills one on purpose.
        silence_dying_thread_reports do
          # A fatal, non-connection error on the listener thread: what a provider
          # that cannot be configured, or any API drift, looks like from here.
          listener.stubs(:connection_provider).raises(NotImplementedError, "no provider")
          SolidQueue.on_thread_error = ->(_error) { nil }
          terminate_listener_backends(listener_backend_pids)

          wait_for(timeout: 15.seconds) { !listener.alive? }
          wait_for(timeout: 5.seconds) { worker.polling_interval != 10.0 }
        end
      end
    end

    assert_equal 0.5, worker.polling_interval, "the worker was left polling every 10s with nothing to wake it"
    assert_nil listen_notify_registry.listener, "the dead listener must be detached"

    restore = events.find { |event| event.payload[:restored] }
    assert restore, "the restore was never instrumented"
    assert_equal 10.0, restore.payload[:from]
    assert_equal 0.5, restore.payload[:to]

    assert_includes log, "listener died permanently"
    assert_includes log, "restored to their original polling intervals"

    # And the worker is still a working worker, now on its own interval.
    enqueue_result_job(queue, "after-crash")
    assert wait_for_job_result("after-crash", timeout: 5.seconds), "polling never picked the job up"
  end
end

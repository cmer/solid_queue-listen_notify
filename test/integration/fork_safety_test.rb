# frozen_string_literal: true

require "integration_helper"

# The landmine this gem was most likely to step on: Puma in clustered mode with
# the async Solid Queue plugin forks a process that already has a listener in it.
#
# The listener's connection was removed from its pool, so ActiveRecord's own
# post-fork cleanup cannot see it — the gem has to deal with it. And it has to
# DISCARD it, not disconnect it: the socket is shared with the parent, and a
# `disconnect!` in the child sends a termination packet down the parent's
# session, silently killing the listener that is still doing real work there.
#
# This test would pass just as happily with either one until you look at the
# parent afterwards, which is exactly what it does.
class ForkSafetyTest < IntegrationTestCase
  # Stands in for a worker in the forked child: registering one there must start
  # a listener, and a real Solid Queue worker in a child of a test process would
  # bring a thread pool and a process registration with it for no benefit.
  class StubWorker
    attr_reader :queues, :name

    def initialize(queue)
      @queues = [ queue ]
      @name = "stub-worker"
    end

    def alive? = true
    def wake_up = nil
    def pool = self
    def idle? = true
  end

  test "a fork leaves the parent's listener alone and gives the child a fresh one" do
    queue = unique_queue("fork_parent")
    worker = start_worker(queues: queue, polling_interval: 60)
    wait_for_listen_notify_registration(worker)

    parent_application_name = SolidQueue::ListenNotify.application_name
    parent_pids = wait_for_listener_backend(application_name: parent_application_name)
    assert_equal 1, parent_pids.size

    reader, writer = IO.pipe

    child_pid = fork do
      reader.close
      exit!(run_child(writer, parent_application_name, parent_pids))
    end

    writer.close
    child_report = reader.read
    reader.close
    _, status = ::Process.waitpid2(child_pid)

    assert_equal 0, status.exitstatus, "the forked child reported:\n#{child_report}"

    # The whole point: same backend, still there.
    assert_equal parent_pids, listener_backend_pids(application_name: parent_application_name),
      "the child's cleanup took the parent's listener session with it"

    # And still doing its job.
    enqueued_at = monotonic_now
    enqueue_result_job(queue, "after-fork")
    assert wait_for_job_result("after-fork", timeout: 3.seconds),
      "the parent's listener stopped waking workers after the fork"

    puts format("\n  post-fork parent wake latency: %.3fs", monotonic_now - enqueued_at)
  end

  private
    # Runs in the forked child. Returns the exit status; every failed expectation
    # is written to the pipe so the parent can put it in the failure message.
    # Never raises out, and never returns through minitest — the caller exits
    # with exit! so that this process does not run at_exit handlers (which would
    # include running the rest of the test suite a second time).
    def run_child(io, parent_application_name, parent_pids)
      registry = SolidQueue::ListenNotify::Registry
      failures = []

      # ActiveSupport::ForkTracker has already run both ActiveRecord's pool
      # discard and this gem's after_fork hook by the time we get here.
      failures << "registry was thrown away entirely" unless registry.instantiated?
      failures << "inherited workers were not cleared" unless registry.instance.workers.empty?
      failures << "inherited listener was not discarded" unless registry.instance.listener.nil?

      child_application_name = SolidQueue::ListenNotify.application_name
      if child_application_name == parent_application_name
        failures << "the child reused the parent's application_name (#{child_application_name})"
      end

      # The failure this test exists to catch is PASSIVE, and without this it
      # never happens inside the child's short life. `discard!` is what drops our
      # end of the inherited file descriptor; if it were ever weakened to a
      # `disconnect!` — or to nothing at all — the inherited PG::Connection would
      # simply become garbage, and libpq's finalizer would run PQfinish on it and
      # send a termination packet down the PARENT's session. Forcing the
      # collection here is what makes that show up now, in the assertions below
      # and in the parent's, rather than in production.
      10.times { GC.start }
      sleep 0.2

      registry.instance.register(StubWorker.new(unique_queue("fork_child")))

      child_pids = []
      begin
        Timeout.timeout(10) do
          loop do
            child_pids = listener_backend_pids(application_name: child_application_name)
            break if child_pids.any?

            sleep 0.05
          end
        end
      rescue Timeout::Error
        failures << "the child never started a listener of its own"
      end

      failures << "the child's listener reused a parent backend" if (child_pids & parent_pids).any?

      still_there = listener_backend_pids(application_name: parent_application_name)
      failures << "the parent's listener was gone by #{parent_pids - still_there}" if (parent_pids - still_there).any?

      registry.reset!

      io.puts(failures) if failures.any?
      failures.empty? ? 0 : 1
    rescue Exception => e # rubocop:disable Lint/RescueException
      io.puts("#{e.class}: #{e.message}", e.backtrace&.first(10))
      2
    ensure
      begin
        io.close
      rescue StandardError
        nil
      end
    end
end

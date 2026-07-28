# frozen_string_literal: true

require "stringio"
require "timeout"

# Everything the integration tier needs to drive real workers, a real listener
# and a real Postgres. The waiting/query-cache helpers are adapted from Solid
# Queue's own test_helper.rb and test_helpers/processes_test_helper.rb.
module IntegrationTestHelper
  LISTENER_APPLICATION_NAME_PATTERN = "solid_queue-listen_notify%"

  SOLID_QUEUE_TABLES = %w[
    ClaimedExecution FailedExecution ReadyExecution ScheduledExecution BlockedExecution
    RecurringExecution Semaphore RecurringTask Pause Job Process
  ].freeze

  # Records ---------------------------------------------------------------

  # Executions first, then jobs: the ready/claimed/… tables carry an ON DELETE
  # CASCADE foreign key to solid_queue_jobs, and deleting jobs first would make
  # Postgres do that cascade row by row for no reason.
  def destroy_records
    SOLID_QUEUE_TABLES.each do |name|
      # inherit: false, so that a name Solid Queue doesn't define can't resolve
      # to a top-level constant instead — SolidQueue::Process would otherwise
      # quietly become ::Process.
      SolidQueue.const_get(name, false).delete_all
    rescue NameError
      # Not every Solid Queue version has every one of these.
      nil
    end

    JobResult.delete_all
  end

  # Waiting ---------------------------------------------------------------

  # Waits until the block returns something truthy and returns it. Timeouts are
  # deliberately generous: the point of these tests is that the wake-up path
  # works, not that it is fast to the millisecond.
  def wait_for(timeout: 3.seconds, interval: 0.05)
    Timeout.timeout(timeout) do
      loop do
        result = skip_active_record_query_cache { yield }
        break result if result

        sleep interval
      end
    end
  end

  def wait_while_with_timeout(timeout, &block)
    wait_while_with_timeout!(timeout, &block)
  rescue Timeout::Error
    nil
  end

  def wait_while_with_timeout!(timeout, &block)
    Timeout.timeout(timeout) do
      skip_active_record_query_cache do
        sleep 0.05 while block.call
      end
    end
  end

  # Rows written by a worker thread (or a forked child) are invisible to a test
  # that already ran the same SELECT on its own connection, because the query
  # cache is per connection. Both databases are involved: the queue tables on
  # SolidQueue::Record, JobResult on the primary.
  def skip_active_record_query_cache(&block)
    SolidQueue::Record.uncached { JobResult.uncached(&block) }
  end

  # Workers ---------------------------------------------------------------

  def started_workers
    @started_workers ||= []
  end

  # Plain async mode: Worker#start spawns a thread, runs the boot callbacks (and
  # therefore this gem's start hook) in it, and returns immediately — so every
  # caller has to wait for something before asserting.
  def start_worker(queues:, polling_interval: 60, threads: 1, await_registration: true)
    worker = SolidQueue::Worker.new(queues: queues, threads: threads, polling_interval: polling_interval)
    started_workers << worker
    worker.start

    wait_for(timeout: 10.seconds) { registered_worker_names.include?(worker.name) } if await_registration

    worker
  end

  def registered_worker_names
    SolidQueue::Process.where(kind: "Worker").pluck(:name)
  end

  def wait_for_listen_notify_registration(worker, timeout: 10.seconds)
    wait_for(timeout: timeout) { listen_notify_registry.workers.include?(worker) }
  end

  # Called from the base class's teardown, so no test has to remember to.
  def stop_workers
    workers = started_workers.dup
    started_workers.clear

    workers.each do |worker|
      begin
        worker.stop
      rescue StandardError, ScriptError
        # Worker#stop joins the worker thread and re-raises whatever killed it.
        # Reporting that here would replace the test's own failure.
        nil
      end

      kill_running_jobs_in(worker)
    end
  end

  # A worker stopped in-process gives up on its pool after shutdown_timeout but
  # cannot stop the thread running the job; a forked worker's exit would kill it.
  # Copied from Solid Queue's processes_test_helper.rb, where the comment
  # explains what the leaked thread does to later tests.
  def kill_running_jobs_in(worker)
    worker&.pool&.send(:executor)&.kill
  rescue StandardError
    nil
  end

  # Listener --------------------------------------------------------------

  def listen_notify_registry
    SolidQueue::ListenNotify::Registry.instance
  end

  # pg_stat_activity is cluster-wide, so this is scoped to the queue database as
  # well as to the application_name the listener sets — otherwise a listener
  # belonging to some other checkout on the same Postgres would count.
  def listener_backend_pids(application_name: nil)
    SolidQueue::Record.connection_pool.with_connection do |connection|
      sql = +"SELECT pid FROM pg_stat_activity WHERE datname = current_database() " \
            "AND application_name LIKE #{connection.quote(LISTENER_APPLICATION_NAME_PATTERN)}"
      sql << " AND application_name = #{connection.quote(application_name)}" if application_name

      connection.uncached { connection.select_values(sql).map(&:to_i) }
    end
  end

  def wait_for_listener_backend(timeout: 10.seconds, application_name: nil)
    wait_for(timeout: timeout) { listener_backend_pids(application_name: application_name).presence }
  end

  # Ruby prints the backtrace of any thread that dies with an exception. A test
  # that kills one on purpose does not need that in its output.
  def silence_dying_thread_reports
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end

  def terminate_listener_backends(pids)
    SolidQueue::Record.connection_pool.with_connection do |connection|
      list = pids.map { |pid| connection.quote(pid) }.join(", ")
      connection.select_values("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid IN (#{list})")
    end
  end

  # Trigger ---------------------------------------------------------------

  def with_queue_connection(&block)
    SolidQueue::ListenNotify.with_queue_connection(&block)
  end

  def trigger_installer(connection, channel: SolidQueue::ListenNotify.channel)
    SolidQueue::ListenNotify::TriggerInstaller.new(connection: connection, channel: channel)
  end

  def install_trigger!(channel: SolidQueue::ListenNotify.channel)
    with_queue_connection { |connection| trigger_installer(connection, channel: channel).install! }
  end

  def uninstall_trigger!
    with_queue_connection { |connection| trigger_installer(connection).uninstall! }
  end

  def trigger_installed?
    with_queue_connection { |connection| trigger_installer(connection).installed? }
  end

  # A connection of the same kind the listener uses (removed from its pool),
  # LISTENing on the channel, so a test can observe notifications without going
  # anywhere near the gem's own listener.
  def with_listening_connection(channel: SolidQueue::ListenNotify.channel)
    connection = SolidQueue::ListenNotify::ConnectionProvider.new.call
    connection.execute("LISTEN #{connection.quote_column_name(channel)}")
    yield connection
  ensure
    begin
      connection&.disconnect!
    rescue StandardError
      nil
    end
  end

  # Returns the payload of the next notification, or nil if none arrives in
  # time. The wait happens inside libpq, not in a sleep loop.
  def wait_for_notify(connection, timeout: 3)
    payload = nil
    connection.raw_connection.wait_for_notify(timeout) { |_channel, _pid, notified| payload = notified }
    payload
  end

  # Jobs ------------------------------------------------------------------

  # Every test owns its queue names. The trigger notifies the queue name and the
  # listener matches on it, so a leftover row from another test would otherwise
  # be able to wake a worker this test is watching.
  def unique_queue(prefix)
    "#{prefix}_#{SecureRandom.hex(4)}"
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def enqueue_result_job(queue, value = "hello")
    StoreResultJob.set(queue: queue).perform_later(value)
  end

  # Inserting the job is enough: Solid Queue's after_create hook creates the
  # ready execution, which is the row the trigger fires on. Used where a test
  # needs to control the transaction, which `perform_later` doesn't allow
  # (the adapter defers enqueueing until after commit).
  def create_ready_execution(queue)
    SolidQueue::Job.create!(queue_name: queue, class_name: "StoreResultJob", priority: 0)
  end

  def wait_for_job_result(value, timeout: 3.seconds)
    wait_for(timeout: timeout) { JobResult.find_by(value: value, status: "completed") }
  end

  # Instrumentation -------------------------------------------------------

  # Events arrive on the listener thread, so the buffer has to be thread-safe.
  def capture_listen_notify_events(*names)
    captured = Concurrent::Array.new

    subscribers = names.map do |name|
      ActiveSupport::Notifications.subscribe("#{name}.solid_queue_listen_notify") do |*args|
        captured << ActiveSupport::Notifications::Event.new(*args)
      end
    end

    yield captured
    captured
  ensure
    subscribers&.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
  end

  # Lifecycle hooks -------------------------------------------------------
  #
  # The Railtie installs this gem's hooks once, at boot. A test that clears or
  # adds hooks would otherwise leave every later test without them, so the base
  # class snapshots and restores them around each test.

  def snapshot_lifecycle_hooks
    SolidQueue::Worker.lifecycle_hooks.transform_values(&:dup)
  end

  def restore_lifecycle_hooks(snapshot)
    snapshot.each { |event, blocks| SolidQueue::Worker.lifecycle_hooks[event] = blocks }
  end

  def reset_listen_notify!
    SolidQueue::ListenNotify::Registry.reset!
    SolidQueue::ListenNotify.reset!
  end
end

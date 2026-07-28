# Writes one JobResult row per run. The queue is always passed explicitly by the
# tests (`set(queue: ...)`) so that each test can own a queue name nothing else
# in the suite notifies on.
class StoreResultJob < ApplicationJob
  def perform(value, status: :completed, pause: nil)
    result = JobResult.create!(queue_name: queue_name, status: "started", value: value)

    sleep(pause) if pause

    result.update!(status: status)
  end
end

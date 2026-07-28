# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_support.deprecation = :stderr

  config.solid_queue.connects_to = { database: { writing: :queue } }
end

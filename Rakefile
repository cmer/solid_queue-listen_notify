# frozen_string_literal: true

require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"

namespace :test do
  desc "Run the unit tests (no Rails app, no database)"
  Rake::TestTask.new(:unit) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/unit/**/*_test.rb"]
    t.warning = false
  end

  desc "Run the integration tests (boots test/dummy against a real Postgres)"
  Rake::TestTask.new(:integration) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/integration/**/*_test.rb"]
    t.warning = false
  end
end

desc "Run all tests"
task test: [ "test:unit", "test:integration" ]

task default: :test

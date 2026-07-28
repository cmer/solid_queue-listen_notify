# frozen_string_literal: true

require_relative "lib/solid_queue/listen_notify/version"

Gem::Specification.new do |spec|
  spec.name        = "solid_queue-listen_notify"
  spec.version     = SolidQueue::ListenNotify::VERSION
  spec.authors     = [ "Carl Mercier" ]
  spec.email       = [ "carl@carlmercier.com" ]
  spec.homepage    = "https://github.com/cmer/solid_queue-listen_notify"
  spec.summary     = "Near-instant job pickup for Solid Queue, using Postgres LISTEN/NOTIFY."
  spec.description = "A database trigger notifies Solid Queue workers the moment a job becomes " \
                     "ready, so jobs start in milliseconds even with polling intervals raised to " \
                     "seconds or minutes — which cuts the idle query load that polling generates by " \
                     "orders of magnitude. No monkey patches: the gem wires itself in through Solid " \
                     "Queue's documented lifecycle hooks. Polling remains the correctness backstop, " \
                     "and every failure mode — missing trigger, non-Postgres adapter, PgBouncer, a " \
                     "dropped connection, a fork — degrades loudly to stock Solid Queue behavior."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/README.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |file|
      file.start_with?("test/", "gemfiles/", ".github/", "bin/") ||
        [ ".gitignore", ".rubocop.yml", "Appraisals", "Gemfile", "Rakefile", "docker-compose.yml" ].include?(file)
    end
  end

  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "solid_queue", ">= 1.5"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "pg", ">= 1.5"
end

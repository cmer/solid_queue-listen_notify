# frozen_string_literal: true

# Only railties is pinned, exactly as Solid Queue's own Appraisals does: every
# other framework gem shares an exact activesupport dependency with it, so
# pinning railties pins the whole Rails version. The dummy app boots three
# frameworks and no more, and asking for the `rails` metagem here would install
# half a dozen it never loads.

# Two Rails pins, matching CI's edge-cell strategy: the oldest supported
# version and the newest. Intermediate versions sit strictly between them.
appraise "rails-7-1" do
  gem "railties", "~> 7.1.0"
end

appraise "solid-queue-1-6" do
  gem "railties", "~> 7.1.0"
  gem "solid_queue", "~> 1.6.0"
end

appraise "rails-8-1" do
  gem "railties", "~> 8.1.0"
end

# Early warning against upstream drift: this gem leans on Solid Queue APIs that
# are public by visibility but not all documented contract (wake_up, pool.idle?,
# alive?), so we want to know the day main breaks one of them — before a
# release does. CI runs this cell as allowed-to-fail.
appraise "solid-queue-main" do
  gem "railties", "~> 8.1.0"
  gem "solid_queue", github: "rails/solid_queue", branch: "main"
end

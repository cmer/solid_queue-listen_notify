# frozen_string_literal: true

require "minitest/autorun"
require "mocha/minitest"

require "solid_queue/listen_notify"

require_relative "test_helpers/config_test_helper"

class Minitest::Test
  include ConfigTestHelper
end

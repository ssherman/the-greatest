# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ConfigTest < ActiveSupport::TestCase
    test "resolve returns the defaults with overrides applied and leaves globals untouched" do
      resolved = Config.resolve(max_per_author: 1)
      assert_equal 1, resolved[:max_per_author]
      assert_equal 10, resolved[:free_limit]
      assert_equal 2, Rails.application.config.x.recommendations[:max_per_author]
    end
  end
end

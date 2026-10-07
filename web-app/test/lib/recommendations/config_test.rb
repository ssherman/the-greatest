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

    test "resolve applies string-keyed overrides" do
      assert_equal 1, Config.resolve("max_per_author" => 1)[:max_per_author]
    end

    test "resolve raises on unknown keys, naming them" do
      error = assert_raises(ArgumentError) { Config.resolve(max_per_autor: 1, nope: 2) }
      assert_includes error.message, "max_per_autor"
      assert_includes error.message, "nope"
    end

    test "resolve accepts nil overrides" do
      assert_equal 10, Config.resolve(nil)[:free_limit]
    end
  end
end

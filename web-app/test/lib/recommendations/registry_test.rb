# frozen_string_literal: true

require "test_helper"

module Recommendations
  class RegistryTest < ActiveSupport::TestCase
    test "books resolves to the books adapter and unknown domains to nil" do
      assert_equal Recommendations::Books::Adapter, Registry.adapter_class_for("books")
      assert_equal Recommendations::Books::Adapter, Registry.adapter_class_for(:books)
      assert_nil Registry.adapter_class_for("music")
    end
  end
end

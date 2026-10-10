# frozen_string_literal: true

require "test_helper"

module Recommendations
  class RegistryTest < ActiveSupport::TestCase
    test "books resolves to the books adapter and unknown domains to nil" do
      assert_equal Recommendations::Books::Adapter, Registry.adapter_class_for("books")
      assert_equal Recommendations::Books::Adapter, Registry.adapter_class_for(:books)
      assert_nil Registry.adapter_class_for("music")
    end

    test "resolves the books adapter, pages and membership feature" do
      assert_equal Recommendations::Books::Adapter, Registry.adapter_class_for(:books)
      assert_equal Recommendations::Books::Pages, Registry.pages_class_for("books")
      assert_equal :book_recommendations, Registry.membership_feature_for(:books)
    end

    test "an unknown domain resolves to nothing" do
      assert_nil Registry.adapter_class_for(:music)
      assert_nil Registry.pages_class_for(:music)
      assert_nil Registry.membership_feature_for(:music)
    end

    test "pairs class per domain" do
      assert_equal Books::PositivePairs, Registry.pairs_class_for(:books)
      assert_nil Registry.pairs_class_for(:music)
    end
  end
end

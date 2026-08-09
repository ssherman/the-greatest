# frozen_string_literal: true

require "test_helper"

module Books
  class BookTypeTest < ActiveSupport::TestCase
    setup do
      ::Books::BookType.reset_category_ids!
    end

    teardown do
      ::Books::BookType.reset_category_ids!
    end

    test "labels every legacy book_type value" do
      assert_equal "Fiction", ::Books::BookType.label(0)
      assert_equal "Nonfiction", ::Books::BookType.label(1)
      assert_equal "Religion & Spirituality", ::Books::BookType.label(2)
      assert_equal "Poetry", ::Books::BookType.label(3)
    end

    test "labels an unknown value as nil" do
      assert_nil ::Books::BookType.label(9)
      assert_nil ::Books::BookType.label(nil)
    end

    test "exposes the legacy category id" do
      assert_equal 40348, ::Books::BookType.legacy_category_id(0)
      assert_equal 47008, ::Books::BookType.legacy_category_id(2)
      assert_nil ::Books::BookType.legacy_category_id(9)
    end

    test "resolves this database's category id through LegacyIdMap" do
      category = ::Books::Category.create!(name: "BookType Target Genre", category_type: :genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: 40348, new_id: category.id)
      ::Books::BookType.reset_category_ids!

      assert_equal category.id, ::Books::BookType.category_id(0)
    end

    test "returns nil when the legacy category has no mapping" do
      assert_nil ::Books::BookType.category_id(3)
    end

    test "returns nil for an unknown book_type without touching the map" do
      assert_nil ::Books::BookType.category_id(9)
    end

    test "memoizes the map so repeated lookups issue one query" do
      category = ::Books::Category.create!(name: "BookType Memo Genre", category_type: :genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: 41013, new_id: category.id)
      ::Books::BookType.reset_category_ids!

      ::Books::BookType.category_id(1)

      assert_queries_count(0) do
        3.times { ::Books::BookType.category_id(1) }
      end
    end
  end
end

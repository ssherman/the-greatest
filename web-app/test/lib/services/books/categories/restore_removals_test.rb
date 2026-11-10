# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Categories
      class RestoreRemovalsTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Restore Book", first_published_year: 1900, original_language: languages(:english))
          @cat = ::Books::Category.create!(name: "Restore Genre", category_type: "genre")
          @held = ::Books::Category.create!(name: "Restore Held", category_type: "genre")
          @gone = ::Books::Category.create!(name: "Restore Gone", category_type: "genre", deleted: true)
        end

        def row(removed, label: "r1")
          @book.enrichments.create!(kind: "books.categories", mode: :knowledge, outcome: :applied,
            facts: {"label" => label, "apply" => {"removed" => removed}})
        end

        def entry(cat) = {"id" => cat.id, "name" => cat.name, "type" => cat.category_type, "source" => "legacy"}

        test "re-creates removed links as legacy and skips deleted categories and links already held" do
          @book.category_items.create!(category: @held, source: :admin)
          row([entry(@cat), entry(@held), entry(@gone)])
          data = RestoreRemovals.call(label: "r1", apply: true).data
          assert_equal [1, 1, 2], [data[:books], data[:links], data[:skipped]]
          assert_equal "legacy", CategoryItem.find_by(item: @book, category_id: @cat.id).source
          assert_equal "admin", CategoryItem.find_by(item: @book, category_id: @held.id).source
          assert_nil CategoryItem.find_by(item: @book, category_id: @gone.id)
        end

        test "a dry run writes nothing" do
          row([entry(@cat)])
          data = RestoreRemovals.call(label: "r1", apply: false).data
          assert_equal 1, data[:links]
          assert_nil CategoryItem.find_by(item: @book, category_id: @cat.id)
        end

        test "other labels are left alone" do
          row([entry(@cat)], label: "other")
          assert_equal 0, RestoreRemovals.call(label: "r1", apply: true).data[:links]
        end

        test "a blank label is refused" do
          refute RestoreRemovals.call(label: "", apply: true).success?
        end
      end
    end
  end
end

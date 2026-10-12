require "test_helper"

module Categories
  class AncestorReconcilerTest < ActiveSupport::TestCase
    setup do
      @na = location("North America")
      @us = location("United States", parent: @na)
      @il = location("Illinois", parent: @us)
      @chicago = location("Chicago", parent: @il)
      @springfield = location("Springfield", parent: @il)
      @book = books_books(:war_and_peace)
    end

    def location(name, parent: nil)
      ::Books::Category.create!(name: name, category_type: :location, parent: parent)
    end

    def link(category, source: :legacy, item: @book)
      CategoryItem.create!(category: category, item: item, source: source)
    end

    def inherited_ids(item = @book)
      CategoryItem.where(item: item).source_inherited.pluck(:category_id).sort
    end

    test "adds every ancestor of a direct location link as inherited" do
      link(@chicago)

      result = AncestorReconciler.call(item_ids: [@book.id])

      assert result.success?
      assert_equal 3, result.data[:added]
      assert_equal [@na.id, @us.id, @il.id].sort, inherited_ids
    end

    test "is idempotent" do
      link(@chicago)
      AncestorReconciler.call(item_ids: [@book.id])

      result = AncestorReconciler.call(item_ids: [@book.id])

      assert_equal [0, 0], [result.data[:added], result.data[:removed]]
    end

    test "removes inherited links whose descendant is gone" do
      chicago_link = link(@chicago)
      AncestorReconciler.call(item_ids: [@book.id])
      chicago_link.destroy!

      result = AncestorReconciler.call(item_ids: [@book.id])

      assert_equal 3, result.data[:removed]
      assert_equal [], inherited_ids
    end

    test "keeps an inherited link another descendant still needs" do
      chicago_link = link(@chicago)
      link(@springfield)
      AncestorReconciler.call(item_ids: [@book.id])
      chicago_link.destroy!

      AncestorReconciler.call(item_ids: [@book.id])

      assert_equal [@na.id, @us.id, @il.id].sort, inherited_ids
    end

    test "never touches a direct link to an ancestor" do
      chicago_link = link(@chicago)
      link(@us, source: :admin)
      AncestorReconciler.call(item_ids: [@book.id])
      chicago_link.destroy!

      AncestorReconciler.call(item_ids: [@book.id])

      assert CategoryItem.exists?(item: @book, category: @us, source: :admin)
    end

    test "skips a soft-deleted parent and everything above it" do
      @il.update!(deleted: true)
      link(@chicago)

      AncestorReconciler.call(item_ids: [@book.id])

      assert_equal [], inherited_ids
    end

    test "with no item_ids it reconciles every book and recounts what it touched" do
      other = books_books(:crime_and_punishment)
      link(@chicago)
      link(@springfield, item: other)

      AncestorReconciler.call

      assert_equal [@na.id, @us.id, @il.id].sort, inherited_ids(other)
      assert_equal 2, @il.reload.item_count
    end

    test "an empty item_ids list does nothing" do
      link(@chicago)
      assert_equal 0, AncestorReconciler.call(item_ids: []).data[:added]
    end

    test "queues a reindex for every item it changed" do
      link(@chicago)
      assert_difference -> { SearchIndexRequest.where(parent: @book).count }, 1 do
        AncestorReconciler.call(item_ids: [@book.id])
      end
    end

    test "leaves music categories alone" do
      rock = categories(:music_rock_genre)
      before = CategoryItem.where(category: rock).pluck(:id, :source)
      link(@chicago)

      AncestorReconciler.call

      assert_equal before, CategoryItem.where(category: rock).pluck(:id, :source)
    end
  end
end

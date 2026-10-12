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
      parent = ::Music::Category.create!(name: "Music Region", category_type: :location)
      child = ::Music::Category.create!(name: "Music City", category_type: :location)
      child.update_column(:parent_id, parent.id)
      CategoryItem.create!(category: child, item: music_albums(:animals), source: :legacy)
      CategoryItem.create!(category: parent, item: music_albums(:animals), source: :inherited)
      music_ids = [parent.id, child.id]
      before_rows = CategoryItem.where(category_id: music_ids).order(:id).pluck(:id, :category_id, :source)
      before_counts = Category.where(id: music_ids).order(:id).pluck(:id, :item_count)
      link(@chicago)

      AncestorReconciler.call

      assert_equal before_rows, CategoryItem.where(category_id: music_ids).order(:id).pluck(:id, :category_id, :source)
      assert_equal before_counts, Category.where(id: music_ids).order(:id).pluck(:id, :item_count)
    end

    test "never links a book to a non-books parent of a books location" do
      rock = categories(:music_rock_genre)
      before_count = rock.reload.item_count
      @na.update_column(:parent_id, rock.id)
      link(@chicago)

      AncestorReconciler.call(item_ids: [@book.id])

      assert_not CategoryItem.exists?(category_id: rock.id, item: @book)
      assert_equal before_count, rock.reload.item_count
    end

    test "re-runs its writes inside a query-cached scope" do
      link(@chicago)

      ActiveRecord::Base.cache do
        AncestorReconciler.call(item_ids: [@book.id])
        # A no-op run writes nothing, so its summaries stay in the query cache.
        AncestorReconciler.call(item_ids: [@book.id])
        CategoryItem.connection.raw_connection.exec("DELETE FROM category_items WHERE source = #{CategoryItem.sources.fetch("inherited")}")

        result = AncestorReconciler.call(item_ids: [@book.id])

        assert_equal 3, result.data[:added]
      end
      assert_equal [@na.id, @us.id, @il.id].sort, inherited_ids
    end

    test "moves inherited links when a location is re-parented" do
      indiana = location("Indiana", parent: @us)
      link(@chicago)
      AncestorReconciler.call(item_ids: [@book.id])
      assert_equal 1, @il.reload.item_count

      @chicago.update!(parent: indiana)
      AncestorReconciler.call(item_ids: [@book.id])

      assert_not CategoryItem.exists?(category: @il, item: @book)
      assert CategoryItem.exists?(category: indiana, item: @book, source: :inherited)
      assert_equal 0, @il.reload.item_count
      assert_equal 1, indiana.reload.item_count
    end
  end
end

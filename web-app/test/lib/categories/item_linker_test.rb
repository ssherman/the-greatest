require "test_helper"

module Categories
  class ItemLinkerTest < ActiveSupport::TestCase
    setup do
      @na = location("North America")
      @us = location("United States", parent: @na)
      @il = location("Illinois", parent: @us)
      @chicago = location("Chicago", parent: @il)
      @springfield = location("Springfield", parent: @il)
      @book = books_books(:war_and_peace)
      @book.category_items.destroy_all
    end

    def location(name, parent: nil)
      ::Books::Category.create!(name: name, category_type: :location, parent: parent)
    end

    test "link creates an admin row and returns the item's category items" do
      result = ItemLinker.link(item: @book, category: @chicago)

      assert result.success?
      assert_equal "admin", CategoryItem.find_by(item: @book, category: @chicago).source
      assert_includes result.data.map(&:category_id), @chicago.id
      assert_includes result.data.map(&:category_id), @il.id # reconciled ancestor
    end

    test "link upgrades an inherited row to admin" do
      CategoryItem.create!(category: @us, item: @book, source: :inherited)

      result = ItemLinker.link(item: @book, category: @us)

      assert result.success?
      assert_equal "admin", CategoryItem.find_by(item: @book, category: @us).source
    end

    test "re-linking a direct row succeeds with one row and no change" do
      ItemLinker.link(item: @book, category: @chicago)

      assert_no_difference "CategoryItem.count" do
        result = ItemLinker.link(item: @book, category: @chicago)
        assert result.success?
      end
    end

    test "link keeps a legacy source as is" do
      CategoryItem.create!(category: @chicago, item: @book, source: :legacy)

      assert ItemLinker.link(item: @book, category: @chicago).success?
      assert_equal "legacy", CategoryItem.find_by(item: @book, category: @chicago).source
    end

    test "link refuses a category from another section" do
      result = ItemLinker.link(item: @book, category: categories(:music_rock_genre))

      refute result.success?
      assert_equal "That category belongs to a different section.", result.errors.first
    end

    test "link refuses a deleted unmerged category" do
      @chicago.update!(deleted: true)

      result = ItemLinker.link(item: @book, category: @chicago)

      refute result.success?
      assert_equal "That category has been deleted.", result.errors.first
    end

    test "link refuses a merged category and names its target" do
      target = location("Chicagoland")
      @chicago.update!(deleted: true, merged_into: target)

      result = ItemLinker.link(item: @book, category: @chicago)

      refute result.success?
      assert_equal "That category was merged into Chicagoland (#{target.id}).", result.errors.first
    end

    test "link treats a merge into a deleted target as deleted" do
      target = location("Gone")
      target.update!(deleted: true)
      @chicago.update!(deleted: true, merged_into: target)

      assert_equal "That category has been deleted.", ItemLinker.link(item: @book, category: @chicago).errors.first
    end

    test "reconciles ancestors for a book" do
      ::Categories::AncestorReconciler.expects(:call).with(item_ids: [@book.id]).twice.returns(nil)

      ItemLinker.link(item: @book, category: @chicago)
      ItemLinker.unlink(item: @book, category: @chicago)
    end

    test "does not reconcile for an author" do
      author = books_authors(:tolstoy)
      ::Categories::AncestorReconciler.expects(:call).never

      assert ItemLinker.link(item: author, category: categories(:books_fiction_genre)).success?
    end

    test "unlink removes a direct row and its now-unneeded inherited ancestors" do
      ItemLinker.link(item: @book, category: @chicago)

      result = ItemLinker.unlink(item: @book, category: @chicago)

      assert result.success?
      assert_empty CategoryItem.where(item: @book)
      assert_empty result.data
    end

    test "unlink refuses an inherited row and names the direct location" do
      ItemLinker.link(item: @book, category: @chicago)

      result = ItemLinker.unlink(item: @book, category: @us)

      refute result.success?
      assert_equal "United States comes from Chicago; remove that instead.", result.errors.first
      assert CategoryItem.exists?(item: @book, category: @us)
    end

    test "unlink names both direct locations sharing the ancestor" do
      ItemLinker.link(item: @book, category: @chicago)
      ItemLinker.link(item: @book, category: @springfield)

      result = ItemLinker.unlink(item: @book, category: @il)

      assert_equal "Illinois comes from Chicago, Springfield; remove that instead.", result.errors.first
    end

    test "unlink of a category the item does not have fails" do
      result = ItemLinker.unlink(item: @book, category: @chicago)

      refute result.success?
      assert_equal "That item doesn't have that category.", result.errors.first
    end

    test "inherited_from returns the direct locations behind the category" do
      ItemLinker.link(item: @book, category: @chicago)
      ItemLinker.link(item: @book, category: @springfield)

      assert_equal [@chicago.id, @springfield.id].sort, ItemLinker.inherited_from(item: @book, category: @na).map(&:id).sort
    end

    test "inherited_map answers every category in one pass" do
      ItemLinker.link(item: @book, category: @chicago)

      map = ItemLinker.inherited_map(item: @book)

      assert_equal [@chicago.id], map[@us.id].map(&:id)
      assert_nil map[@chicago.id]
    end

    test "works for a music category on a music album" do
      album = music_albums(:dark_side_of_the_moon)
      album.category_items.destroy_all
      genre = categories(:music_rock_genre)

      assert ItemLinker.link(item: album, category: genre).success?
      assert ItemLinker.link(item: album, category: genre).success?
      assert_equal 1, CategoryItem.where(item: album, category: genre).count
      assert ItemLinker.unlink(item: album, category: genre).success?
      assert_empty CategoryItem.where(item: album)
    end

    test "link treats a uniqueness RecordInvalid from a concurrent tag as success" do
      row = CategoryItem.new(category: @chicago, item: @book)
      row.errors.add(:category_id, :taken)
      @book.category_items.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(row))

      assert ItemLinker.link(item: @book, category: @chicago).success?
    end

    test "unlink of an orphaned inherited row reconciles it away and succeeds" do
      CategoryItem.create!(category: @il, item: @book, source: :inherited)

      assert ItemLinker.unlink(item: @book, category: @il).success?
      assert_nil CategoryItem.find_by(item: @book, category: @il)
    end

    test "inherited_map does not name a location behind a deleted intermediate" do
      ItemLinker.link(item: @book, category: @chicago)
      @il.update_columns(deleted: true)

      map = ItemLinker.inherited_map(item: @book)

      assert_nil map[@us.id]
      assert_nil map[@na.id]
    end

    test "inherited_map ignores a deleted direct location" do
      ItemLinker.link(item: @book, category: @chicago)
      @chicago.update_columns(deleted: true)

      assert_empty ItemLinker.inherited_map(item: @book)
    end
  end
end

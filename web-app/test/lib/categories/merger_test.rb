require "test_helper"

module Categories
  class MergerTest < ActiveSupport::TestCase
    def setup
      @rock_category = categories(:music_rock_genre)
      @progressive_category = categories(:music_progressive_rock_genre)
      @uk_location = categories(:music_uk_location)

      # Create a test category to merge from
      @source_category = Music::Category.create!(
        name: "Alternative Rock",
        category_type: "genre",
        description: "Alternative rock music",
        alternative_names: ["Alt Rock"]
      )

      # Add some items to the source category (use animals which isn't in rock category yet)
      CategoryItem.create!(category: @source_category, item: music_albums(:animals))

      @source_category.reload
    end

    test "should merge category items from source to target" do
      initial_rock_items = @rock_category.category_items.to_a
      source_items = @source_category.category_items.to_a

      merger = Categories::Merger.new(
        category: @source_category,
        category_to_merge_with: @rock_category
      )

      result = merger.merge

      @rock_category.reload

      # Should return the target category
      assert_equal @rock_category, result

      # All source items should now be in the target category
      source_items.each do |source_item|
        assert @rock_category.category_items.exists?(item: source_item.item),
          "Item #{source_item.item.title} should be in target category"
      end

      # Target should have original items plus source items (only 1 source item now)
      expected_count = initial_rock_items.count + 1  # animals album
      assert_equal expected_count, @rock_category.category_items.count
    end

    test "should handle duplicate items gracefully" do
      # Add an item that already exists in the target (dark_side_of_the_moon is in rock category)
      existing_item = music_albums(:dark_side_of_the_moon)

      # Create a fresh source category for this test to avoid setup conflicts
      duplicate_source = Music::Category.create!(
        name: "Duplicate Test",
        category_type: "genre"
      )
      CategoryItem.create!(category: duplicate_source, item: existing_item)

      @rock_category.category_items.count

      merger = Categories::Merger.new(
        category: duplicate_source,
        category_to_merge_with: @rock_category
      )

      # Should not raise error due to find_or_create_by!
      assert_nothing_raised do
        merger.merge
      end

      @rock_category.reload

      # Should not create duplicate associations
      rock_items_for_existing = @rock_category.category_items.where(item: existing_item)
      assert_equal 1, rock_items_for_existing.count, "Should not create duplicate associations"
    end

    test "should add source category name to alternative_names" do
      initial_alternatives = @rock_category.alternative_names.dup

      merger = Categories::Merger.new(
        category: @source_category,
        category_to_merge_with: @rock_category
      )

      merger.merge

      @rock_category.reload

      assert_includes @rock_category.alternative_names, "Alternative Rock"
      assert_equal initial_alternatives + ["Alternative Rock"], @rock_category.alternative_names
    end

    test "should not create duplicate alternative names" do
      # Add the source name to target's alternative names first
      @rock_category.update!(alternative_names: ["Alternative Rock", "Rock Music"])

      merger = Categories::Merger.new(
        category: @source_category,
        category_to_merge_with: @rock_category
      )

      merger.merge

      @rock_category.reload

      # Should only have one instance of "Alternative Rock"
      alt_rock_count = @rock_category.alternative_names.count("Alternative Rock")
      assert_equal 1, alt_rock_count, "Should not create duplicate alternative names"
    end

    test "should preserve existing alternative names from source" do
      merger = Categories::Merger.new(
        category: @source_category,
        category_to_merge_with: @rock_category
      )

      merger.merge

      @rock_category.reload

      # Source category had alternative_names: ["Alt Rock"]
      # After merge, target should have the source's name but not its alternative names
      assert_includes @rock_category.alternative_names, "Alternative Rock"
      assert_not_includes @rock_category.alternative_names, "Alt Rock"
    end

    test "should soft delete source category after merge" do
      merger = Categories::Merger.new(
        category: @source_category,
        category_to_merge_with: @rock_category
      )

      assert_not @source_category.deleted?

      merger.merge

      @source_category.reload
      assert @source_category.deleted?, "Source category should be soft deleted"
      assert Category.exists?(@source_category.id), "Source category should still exist in database"
    end

    test "should update counter cache correctly" do
      initial_rock_count = @rock_category.item_count
      @source_category.item_count

      merger = Categories::Merger.new(
        category: @source_category,
        category_to_merge_with: @rock_category
      )

      merger.merge

      @rock_category.reload
      @source_category.reload

      # Rock category should have gained items (accounting for potential duplicates)
      assert_operator @rock_category.item_count, :>, initial_rock_count

      # Source category should have 0 items after soft delete
      assert_equal 0, @source_category.item_count
    end

    test "should work within database transaction" do
      # Mock an error during alternative names update to test rollback
      @rock_category.stubs(:save!).raises(ActiveRecord::RecordInvalid)

      merger = Categories::Merger.new(
        category: @source_category,
        category_to_merge_with: @rock_category
      )

      initial_rock_items = @rock_category.category_items.count

      assert_raises(ActiveRecord::RecordInvalid) do
        merger.merge
      end

      @rock_category.reload
      @source_category.reload

      # Should rollback all changes
      assert_equal initial_rock_items, @rock_category.category_items.count
      assert_not @source_category.deleted?, "Source should not be deleted due to rollback"
    end

    test "should handle merging categories of different types" do
      # Create a movies category to merge with music category
      movies_category = Movies::Category.create!(
        name: "Action Movies",
        category_type: "genre"
      )

      merger = Categories::Merger.new(
        category: @source_category,
        category_to_merge_with: movies_category
      )

      # Should work even across STI types
      assert_nothing_raised do
        result = merger.merge
        assert_equal movies_category, result
      end

      movies_category.reload
      assert_includes movies_category.alternative_names, "Alternative Rock"
    end

    test "should handle empty source category" do
      empty_category = Music::Category.create!(
        name: "Empty Genre",
        category_type: "genre"
      )

      assert_equal 0, empty_category.category_items.count

      merger = Categories::Merger.new(
        category: empty_category,
        category_to_merge_with: @rock_category
      )

      initial_rock_count = @rock_category.category_items.count

      result = merger.merge

      @rock_category.reload
      empty_category.reload

      assert_equal @rock_category, result
      assert_equal initial_rock_count, @rock_category.category_items.count
      assert_includes @rock_category.alternative_names, "Empty Genre"
      assert empty_category.deleted?
    end

    test "should handle merging with self gracefully" do
      # This shouldn't happen in normal usage, but let's test it
      # Create a separate category to avoid affecting other tests
      self_merge_category = Music::Category.create!(
        name: "Self Merge Test",
        category_type: "genre"
      )
      CategoryItem.create!(category: self_merge_category, item: music_albums(:animals))
      self_merge_category.reload

      self_merge_category.category_items.count

      merger = Categories::Merger.new(
        category: self_merge_category,
        category_to_merge_with: self_merge_category
      )

      result = merger.merge

      self_merge_category.reload

      assert_equal self_merge_category, result
      # Name should be added to alternatives
      assert_includes self_merge_category.alternative_names, "Self Merge Test"
      # Category should be soft deleted (which is weird but consistent)
      assert self_merge_category.deleted?
      # Items should be 0 due to soft delete cleanup
      assert_equal 0, self_merge_category.category_items.count
    end

    test "should initialize with correct attributes" do
      merger = Categories::Merger.new(
        category: @source_category,
        category_to_merge_with: @rock_category
      )

      assert_equal @source_category, merger.category
      assert_equal @rock_category, merger.category_to_merge_with
    end

    test "should handle hierarchical relationships" do
      # Test merging a parent category with a child
      merger = Categories::Merger.new(
        category: @rock_category,  # Parent of progressive rock
        category_to_merge_with: @uk_location
      )

      merger.merge

      @progressive_category.reload
      @uk_location.reload
      @rock_category.reload

      # Progressive rock should still exist and point to the now-deleted rock category
      assert_not @progressive_category.deleted?
      assert_equal @rock_category, @progressive_category.parent
      assert @rock_category.deleted?
      assert_includes @uk_location.alternative_names, "Rock"
    end
  end
end

require "test_helper"

module Categories
  class DeleterTest < ActiveSupport::TestCase
    def setup
      @rock_category = categories(:music_rock_genre)
      @progressive_category = categories(:music_progressive_rock_genre)
      @uk_location = categories(:music_uk_location)

      # Ensure we have some category items to test cleanup
      @category_item = category_items(:dark_side_rock_category)
    end

    test "should soft delete category by default" do
      deleter = Categories::Deleter.new(category: @uk_location)

      assert_not @uk_location.deleted?
      initial_item_count = @uk_location.category_items.count
      assert_operator initial_item_count, :>, 0, "Category should have items for meaningful test"

      deleter.delete

      @uk_location.reload
      assert @uk_location.deleted?, "Category should be soft deleted"
      assert_equal 0, @uk_location.category_items.count, "Category items should be destroyed"
    end

    test "should soft delete when explicitly specified" do
      deleter = Categories::Deleter.new(category: @uk_location, soft: true)

      assert_not @uk_location.deleted?

      deleter.delete

      @uk_location.reload
      assert @uk_location.deleted?, "Category should be soft deleted"
      assert Category.exists?(@uk_location.id), "Category record should still exist in database"
    end

    test "should hard delete when specified" do
      category_id = @uk_location.id
      deleter = Categories::Deleter.new(category: @uk_location, soft: false)

      deleter.delete

      assert_not Category.exists?(category_id), "Category should be completely removed from database"
    end

    test "should destroy all category_items during soft delete" do
      initial_items = @rock_category.category_items.to_a
      assert_operator initial_items.count, :>, 0, "Category should have items for meaningful test"

      deleter = Categories::Deleter.new(category: @rock_category, soft: true)
      deleter.delete

      @rock_category.reload
      assert_equal 0, @rock_category.category_items.count, "All category items should be destroyed"

      # Verify the items are actually gone from the database
      initial_items.each do |item|
        assert_not CategoryItem.exists?(item.id), "CategoryItem should be destroyed"
      end
    end

    test "should update counter cache when destroying category_items during soft delete" do
      # Create a fresh category with known item count
      fresh_category = Music::Category.create!(
        name: "Test Genre",
        category_type: "genre"
      )

      # Add some items
      CategoryItem.create!(category: fresh_category, item: music_albums(:dark_side_of_the_moon))
      CategoryItem.create!(category: fresh_category, item: music_albums(:wish_you_were_here))

      fresh_category.reload
      assert_equal 2, fresh_category.item_count, "Counter cache should reflect added items"

      deleter = Categories::Deleter.new(category: fresh_category, soft: true)
      deleter.delete

      fresh_category.reload
      assert_equal 0, fresh_category.item_count, "Counter cache should be updated to 0"
    end

    test "should handle category with no items during soft delete" do
      # Create a category with no items
      empty_category = Music::Category.create!(
        name: "Empty Genre",
        category_type: "genre"
      )

      assert_equal 0, empty_category.category_items.count

      deleter = Categories::Deleter.new(category: empty_category, soft: true)

      assert_nothing_raised do
        deleter.delete
      end

      empty_category.reload
      assert empty_category.deleted?
    end

    test "should handle category with child categories during soft delete" do
      # Progressive Rock is a child of Rock
      assert_equal @rock_category, @progressive_category.parent

      deleter = Categories::Deleter.new(category: @rock_category, soft: true)
      deleter.delete

      @rock_category.reload
      @progressive_category.reload

      assert @rock_category.deleted?, "Parent category should be soft deleted"
      assert_not @progressive_category.deleted?, "Child category should not be affected"
      assert_equal @rock_category, @progressive_category.parent, "Parent relationship should remain"
    end

    test "should handle category with child categories during hard delete" do
      # Create a test parent/child relationship to avoid affecting other tests
      parent = Music::Category.create!(name: "Test Parent", category_type: "genre")
      child = Music::Category.create!(name: "Test Child", category_type: "genre", parent: parent)

      parent_id = parent.id
      child_id = child.id

      deleter = Categories::Deleter.new(category: parent, soft: false)
      deleter.delete

      assert_not Category.exists?(parent_id), "Parent should be hard deleted"

      child.reload
      assert_nil child.parent_id, "Child's parent_id should be nullified (due to dependent: :nullify)"
      assert Category.exists?(child_id), "Child should still exist"
    end

    test "should use database transaction for soft delete" do
      # Mock an error during the transaction to test rollback
      @uk_location.stubs(:update_column).raises(ActiveRecord::RecordInvalid)

      deleter = Categories::Deleter.new(category: @uk_location, soft: true)

      assert_raises(ActiveRecord::RecordInvalid) do
        deleter.delete
      end

      @uk_location.reload
      assert_not @uk_location.deleted?, "Category should not be deleted due to transaction rollback"
      assert_operator @uk_location.category_items.count, :>, 0, "Category items should not be destroyed due to rollback"
    end

    test "should initialize with correct default values" do
      deleter = Categories::Deleter.new(category: @rock_category)

      assert_equal @rock_category, deleter.category
      assert_equal true, deleter.soft, "Should default to soft delete"
    end

    test "should initialize with explicit soft parameter" do
      soft_deleter = Categories::Deleter.new(category: @rock_category, soft: true)
      hard_deleter = Categories::Deleter.new(category: @rock_category, soft: false)

      assert_equal true, soft_deleter.soft
      assert_equal false, hard_deleter.soft
    end
  end
end

require "test_helper"

module Categories
  class UpdaterTest < ActiveSupport::TestCase
    def setup
      @rock_category = categories(:music_rock_genre)
      @progressive_category = categories(:music_progressive_rock_genre)
      @uk_location = categories(:music_uk_location)

      # Create a test category with items for testing
      @test_category = Music::Category.create!(
        name: "Test Genre",
        category_type: "genre",
        description: "Original description",
        import_source: "musicbrainz"
      )
      CategoryItem.create!(category: @test_category, item: music_albums(:animals))
      @test_category.reload
    end

    # Simple update tests (no name change)
    test "should update non-name attributes without complications" do
      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {
          description: "Updated description",
          category_type: "location"
        }
      )

      result = updater.update

      assert_equal @test_category, result
      @test_category.reload
      assert_equal "Updated description", @test_category.description
      assert_equal "location", @test_category.category_type
      assert_equal "Test Genre", @test_category.name  # Name unchanged
    end

    test "should return updated category for simple updates" do
      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {description: "New description"}
      )

      result = updater.update

      assert_equal @test_category, result
      assert_equal @test_category.id, result.id
    end

    # Name change to new name tests
    test "should create new category when name changes to new name" do
      original_id = @test_category.id
      original_item_count = @test_category.category_items.count

      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: "Renamed Genre"}
      )

      result = updater.update

      # Should return a new category
      assert_not_equal @test_category, result
      assert_not_equal original_id, result.id
      assert_equal "Renamed Genre", result.name

      # Old name should be in alternative_names
      assert_includes result.alternative_names, "Test Genre"

      # Items should be transferred
      assert_equal original_item_count, result.category_items.count

      # Original category should be soft deleted
      @test_category.reload
      assert @test_category.deleted?
      assert_equal 0, @test_category.category_items.count
    end

    test "should preserve other attributes when creating renamed category" do
      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {
          name: "Renamed Genre",
          description: "Updated description"
        }
      )

      result = updater.update

      assert_equal "Renamed Genre", result.name
      assert_equal "Updated description", result.description
      assert_equal @test_category.category_type, result.category_type
      assert_equal @test_category.import_source, result.import_source
      assert_equal @test_category.parent, result.parent
    end

    test "should reset original category attributes after name change" do
      original_name = @test_category.name

      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: "Renamed Genre"}
      )

      updater.update

      # Original category should have its attributes reset
      @test_category.reload
      assert_equal original_name, @test_category.name
      assert_not_equal "Renamed Genre", @test_category.name
    end

    # Name change to existing name tests
    test "should merge with existing category when name changes to existing name" do
      # Create an existing category with the target name
      existing_category = Music::Category.create!(
        name: "Existing Genre",
        category_type: "genre",
        alternative_names: ["Old Alt"]
      )
      CategoryItem.create!(category: existing_category, item: music_albums(:dark_side_of_the_moon))
      existing_category.reload

      original_existing_count = existing_category.category_items.count
      original_test_count = @test_category.category_items.count

      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: "Existing Genre"}
      )

      result = updater.update

      # Should return the existing category
      assert_equal existing_category, result
      assert_equal existing_category.id, result.id

      # Should have merged items
      result.reload
      expected_count = original_existing_count + original_test_count
      assert_equal expected_count, result.category_items.count

      # Should have added test category name to alternative names
      assert_includes result.alternative_names, "Test Genre"

      # Original test category should be soft deleted
      @test_category.reload
      assert @test_category.deleted?
    end

    test "should restore soft deleted existing category when merging" do
      # Create a soft deleted category with the target name
      deleted_category = Music::Category.create!(
        name: "Unique Deleted Genre",
        category_type: "genre",
        deleted: true
      )

      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: "Unique Deleted Genre"}
      )

      result = updater.update

      assert_equal deleted_category, result
      result.reload
      assert_not result.deleted?, "Existing category should be restored"
    end

    test "should handle case insensitive name matching" do
      existing_category = Music::Category.create!(
        name: "Existing Genre",
        category_type: "genre"
      )

      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: "EXISTING GENRE"}  # Different case
      )

      result = updater.update

      # Should merge with existing category despite case difference
      assert_equal existing_category, result
    end

    test "should only match categories of same STI type" do
      # Create a Movies category with same name
      movies_category = Movies::Category.create!(
        name: "Test Genre",
        category_type: "genre"
      )

      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: "Test Genre"}  # Same name as movies category
      )

      result = updater.update

      # Should not merge with movies category, should create new music category
      assert_not_equal movies_category, result
      assert_instance_of Music::Category, result
      assert_equal "Test Genre", result.name
    end

    # Edge cases and error handling
    test "should handle category with no items during name change" do
      empty_category = Music::Category.create!(
        name: "Empty Genre",
        category_type: "genre"
      )

      updater = Categories::Updater.new(
        category: empty_category,
        attributes: {name: "Renamed Empty"}
      )

      result = updater.update

      assert_equal "Renamed Empty", result.name
      assert_includes result.alternative_names, "Empty Genre"
      assert_equal 0, result.category_items.count

      empty_category.reload
      assert empty_category.deleted?
    end

    test "should handle hierarchical relationships during name change" do
      # Test category with children
      child_category = Music::Category.create!(
        name: "Child Genre",
        category_type: "genre",
        parent: @test_category
      )

      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: "Renamed Parent"}
      )

      result = updater.update

      # Child should still point to original (now deleted) parent
      child_category.reload
      assert_equal @test_category, child_category.parent
      assert @test_category.deleted?

      # New category should not have children initially
      assert_equal 0, result.child_categories.count
    end

    test "should use database transaction for name changes" do
      # Mock an error during category creation to test rollback
      Music::Category.stubs(:create!).raises(ActiveRecord::RecordInvalid)

      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: "Should Fail"}
      )

      assert_raises(ActiveRecord::RecordInvalid) do
        updater.update
      end

      @test_category.reload
      # Should rollback - category should not be deleted
      assert_not @test_category.deleted?
      assert_equal "Test Genre", @test_category.name
    end

    test "should handle validation errors on simple updates" do
      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: ""}  # Invalid - name required
      )

      assert_raises(ActiveRecord::RecordInvalid) do
        updater.update
      end
    end

    test "should initialize with correct attributes" do
      attributes = {name: "New Name", description: "New Description"}

      updater = Categories::Updater.new(
        category: @test_category,
        attributes: attributes
      )

      assert_equal @test_category, updater.category
      assert_equal attributes, updater.attributes

      # Should have applied attributes to category
      assert_equal "New Name", @test_category.name
      assert_equal "New Description", @test_category.description
    end

    test "should detect name changes correctly" do
      # No change
      Categories::Updater.new(
        category: @test_category,
        attributes: {description: "New description"}
      )
      assert_not @test_category.name_changed?

      # With change
      Categories::Updater.new(
        category: @test_category,
        attributes: {name: "New Name"}
      )
      assert @test_category.name_changed?
    end

    test "should handle complex update with multiple attribute changes and name change" do
      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {
          name: "Complex Update",
          description: "Updated description",
          category_type: "location",
          import_source: "openai"
        }
      )

      result = updater.update

      # Should create new category with all updated attributes
      assert_equal "Complex Update", result.name
      assert_equal "Updated description", result.description
      assert_equal "location", result.category_type
      assert_equal "openai", result.import_source
      assert_includes result.alternative_names, "Test Genre"
    end

    test "should preserve slug generation for renamed categories" do
      updater = Categories::Updater.new(
        category: @test_category,
        attributes: {name: "Heavy Metal Music"}
      )

      result = updater.update

      # FriendlyId should generate appropriate slug
      assert_equal "heavy-metal-music", result.slug
    end
  end
end

# == Schema Information
#
# Table name: category_items
#
#  id          :bigint           not null, primary key
#  item_type   :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  category_id :bigint           not null
#  item_id     :bigint           not null
#
# Indexes
#
#  index_category_items_on_category_id                            (category_id)
#  index_category_items_on_category_id_and_item_type_and_item_id  (category_id,item_type,item_id) UNIQUE
#  index_category_items_on_item                                   (item_type,item_id)
#  index_category_items_on_item_type_and_item_id                  (item_type,item_id)
#
# Foreign Keys
#
#  fk_rails_...  (category_id => categories.id)
#
require "test_helper"

class CategoryItemTest < ActiveSupport::TestCase
  def setup
    @rock_category = categories(:music_rock_genre)
    @progressive_category = categories(:music_progressive_rock_genre)
    @dark_side_album = music_albums(:dark_side_of_the_moon)
    @category_item = category_items(:dark_side_rock_category)
  end

  test "should be valid with valid attributes" do
    category_item = CategoryItem.new(
      category: @progressive_category,
      item: music_albums(:animals)  # Use a different album that's not already categorized
    )
    assert category_item.valid?
  end

  test "should require category" do
    category_item = CategoryItem.new(item: @dark_side_album)
    assert_not category_item.valid?
    assert_includes category_item.errors[:category], "must exist"
  end

  test "should require item" do
    category_item = CategoryItem.new(category: @rock_category)
    assert_not category_item.valid?
    assert_includes category_item.errors[:item], "must exist"
  end

  test "should enforce uniqueness of category and item combination" do
    # Try to create duplicate association
    duplicate = CategoryItem.new(
      category: @category_item.category,
      item: @category_item.item
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:category_id], "has already been taken"
  end

  test "should belong to category" do
    assert_equal @rock_category, @category_item.category
    assert_instance_of Music::Category, @category_item.category
  end

  test "should belong to polymorphic item" do
    assert_equal @dark_side_album, @category_item.item
    assert_instance_of Music::Album, @category_item.item
    assert_equal "Music::Album", @category_item.item_type
  end

  test "for_item_type scope should filter by item type" do
    album_items = CategoryItem.for_item_type("Music::Album")
    assert_includes album_items, @category_item

    # Should not include items of other types (when they exist)
  end

  test "for_category_type scope should filter by category STI type" do
    music_items = CategoryItem.for_category_type("Music::Category")
    assert_includes music_items, @category_item

    # Should not include items from other category types
  end

  test "should increment category item_count when created via counter_cache" do
    initial_count = @progressive_category.item_count

    CategoryItem.create!(
      category: @progressive_category,
      item: music_albums(:animals)
    )

    @progressive_category.reload
    assert_equal initial_count + 1, @progressive_category.item_count
  end

  test "should decrement category item_count when destroyed via counter_cache" do
    # Create a new item to destroy
    new_item = CategoryItem.create!(
      category: @progressive_category,
      item: music_albums(:animals)
    )

    @progressive_category.reload
    initial_count = @progressive_category.item_count

    new_item.destroy

    @progressive_category.reload
    assert_equal initial_count - 1, @progressive_category.item_count
  end

  test "should handle multiple categories for same item" do
    # Dark Side of the Moon should be in multiple categories
    dark_side_categories = CategoryItem.where(item: @dark_side_album)

    assert_operator dark_side_categories.count, :>, 1
    category_names = dark_side_categories.map { |ci| ci.category.name }
    assert_includes category_names, "Rock"
    assert_includes category_names, "Progressive Rock"
    assert_includes category_names, "United Kingdom"
  end

  test "should handle multiple items for same category" do
    rock_items = CategoryItem.where(category: @rock_category)

    assert_operator rock_items.count, :>, 1
    item_names = rock_items.map { |ci| ci.item.title }
    assert_includes item_names, "The Dark Side of the Moon"
    assert_includes item_names, "Wish You Were Here"
  end
end

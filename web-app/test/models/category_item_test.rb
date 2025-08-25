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

  # SearchIndexable behavior tests
  test "should create search index request when category_item is created for music artist" do
    artist = music_artists(:the_beatles)
    category = Music::Category.create!(name: "Rock", type: "Music::Category")

    assert_difference "SearchIndexRequest.count", 1 do
      CategoryItem.create!(category: category, item: artist)
    end

    request = SearchIndexRequest.last
    assert_equal artist, request.parent
    assert request.index_item?
  end

  test "should create search index request when category_item is created for music album" do
    album = music_albums(:dark_side_of_the_moon)
    category = Music::Category.create!(name: "Rock", type: "Music::Category")

    assert_difference "SearchIndexRequest.count", 1 do
      CategoryItem.create!(category: category, item: album)
    end

    request = SearchIndexRequest.last
    assert_equal album, request.parent
    assert request.index_item?
  end

  test "should create search index request when category_item is created for music song" do
    song = music_songs(:time)
    category = Music::Category.create!(name: "Rock", type: "Music::Category")

    assert_difference "SearchIndexRequest.count", 1 do
      CategoryItem.create!(category: category, item: song)
    end

    request = SearchIndexRequest.last
    assert_equal song, request.parent
    assert request.index_item?
  end

  test "should create search index request when category_item is destroyed" do
    artist = music_artists(:the_beatles)
    category = Music::Category.create!(name: "Rock", type: "Music::Category")
    category_item = CategoryItem.create!(category: category, item: artist)

    # Clear any requests created during setup
    SearchIndexRequest.delete_all

    assert_difference "SearchIndexRequest.count", 1 do
      category_item.destroy!
    end

    request = SearchIndexRequest.last
    assert_equal artist, request.parent
    assert request.index_item?
  end

  test "should not create search index request for non-music items" do
    # Create a non-music item (e.g., a user)
    user = users(:regular_user)
    category = Music::Category.create!(name: "Rock", type: "Music::Category")

    assert_no_difference "SearchIndexRequest.count" do
      CategoryItem.create!(category: category, item: user)
    end
  end

  test "should not create search index request if item does not support category indexing" do
    # Create a music item that doesn't have as_indexed_json with category_ids
    # We'll stub the method to return something without category_ids
    artist = music_artists(:the_beatles)
    category = Music::Category.create!(name: "Rock", type: "Music::Category")

    artist.stubs(:as_indexed_json).returns({name: "Test"})

    assert_no_difference "SearchIndexRequest.count" do
      CategoryItem.create!(category: category, item: artist)
    end
  end

  test "should create search index requests when item is destroyed" do
    # Create category item first
    artist = music_artists(:the_beatles)
    category = Music::Category.create!(name: "Rock", type: "Music::Category")
    CategoryItem.create!(category: category, item: artist)

    # Clear any requests created during setup
    SearchIndexRequest.delete_all

    # When we destroy the artist, its category_items will be destroyed too
    # We should get 2 requests: 1 for unindexing the artist + 1 from category_item destruction
    # The Sidekiq job will handle the fact that the artist no longer exists
    assert_difference "SearchIndexRequest.count", 2 do
      artist.destroy!
    end

    requests = SearchIndexRequest.last(2)

    # Should have one unindex request for the artist
    unindex_request = requests.find(&:unindex_item?)
    assert unindex_request
    assert_equal artist.id, unindex_request.parent_id
    assert_equal "Music::Artist", unindex_request.parent_type

    # Should have one index request from the category_item destruction
    index_request = requests.find(&:index_item?)
    assert index_request
    assert_equal artist.id, index_request.parent_id
    assert_equal "Music::Artist", index_request.parent_type
  end

  test "should handle multiple category changes efficiently" do
    # Adding multiple categories should create multiple requests (will be deduplicated by job)
    artist = music_artists(:the_beatles)
    category1 = Music::Category.create!(name: "Rock", type: "Music::Category")
    category2 = Music::Category.create!(name: "Pop", type: "Music::Category")
    category3 = Music::Category.create!(name: "Jazz", type: "Music::Category")

    assert_difference "SearchIndexRequest.count", 3 do
      CategoryItem.create!(category: category1, item: artist)
      CategoryItem.create!(category: category2, item: artist)
      CategoryItem.create!(category: category3, item: artist)
    end

    # All requests should be for the same artist
    requests = SearchIndexRequest.last(3)
    requests.each do |request|
      assert_equal artist, request.parent
      assert request.index_item?
    end
  end
end

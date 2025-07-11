# == Schema Information
#
# Table name: list_items
#
#  id            :bigint           not null, primary key
#  listable_type :string           not null
#  position      :integer
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  list_id       :bigint           not null
#  listable_id   :bigint           not null
#
# Indexes
#
#  index_list_items_on_list_and_listable_unique  (list_id,listable_type,listable_id) UNIQUE
#  index_list_items_on_list_id                   (list_id)
#  index_list_items_on_list_id_and_position      (list_id,position)
#  index_list_items_on_listable                  (listable_type,listable_id)
#
# Foreign Keys
#
#  fk_rails_...  (list_id => lists.id)
#
require "test_helper"

class ListItemTest < ActiveSupport::TestCase
  test "should be valid with valid attributes" do
    assert list_items(:basic_item).valid?
  end

  test "should require list" do
    item = list_items(:basic_item)
    item.list = nil
    assert_not item.valid?
    assert_includes item.errors[:list], "must exist"
  end

  test "should require listable" do
    item = list_items(:basic_item)
    item.listable = nil
    assert_not item.valid?
    assert_includes item.errors[:listable], "must exist"
  end

  test "should accept valid position" do
    item = list_items(:basic_item)
    item.position = 5
    assert item.valid?
  end

  test "should reject invalid position" do
    item = list_items(:basic_item)
    item.position = 0
    assert_not item.valid?
    assert_includes item.errors[:position], "must be greater than 0"
  end

  test "should accept nil position" do
    item = list_items(:basic_item)
    item.position = nil
    assert item.valid?
  end

  test "should prevent duplicate items in same list" do
    # Create a duplicate item with same list and listable
    duplicate_item = ListItem.new(
      list: list_items(:basic_item).list,
      listable_type: list_items(:basic_item).listable_type,
      listable_id: list_items(:basic_item).listable_id
    )
    assert_not duplicate_item.valid?
    assert_includes duplicate_item.errors[:listable_id], "is already in this list"
  end

  test "should allow same item in different lists" do
    # Create item with same listable but different list
    new_item = ListItem.new(
      list: lists(:approved_list),
      listable_type: list_items(:basic_item).listable_type,
      listable_id: list_items(:basic_item).listable_id
    )
    assert new_item.valid?
  end

  test "should allow different items in same list" do
    # Create item with same list but different listable (using the animals album)
    new_item = ListItem.new(
      list: list_items(:basic_item).list,
      listable_type: "Music::Album",
      listable_id: music_albums(:animals).id
    )
    # This should be valid because it's a different listable_id
    assert new_item.valid?
  end

  test "ordered scope should return items by position" do
    # Get items from the same list with different positions
    list = lists(:basic_list)
    list_items = list.list_items.ordered

    # Should have at least 2 items with different positions
    assert list_items.count >= 2
    assert_equal 1, list_items.first.position
    assert_equal 2, list_items.second.position
  end

  test "by_list scope should return items for specific list" do
    list = lists(:basic_list)
    list_items = ListItem.by_list(list)

    assert_includes list_items, list_items(:basic_item)
    assert_includes list_items, list_items(:second_item)
    assert_not_includes list_items, list_items(:approved_item)
  end

  test "by_listable_type scope should return items by type" do
    books_items = ListItem.by_listable_type("Books::Book")
    movies_items = ListItem.by_listable_type("Movies::Movie")

    assert_includes books_items, list_items(:books_item)
    assert_includes movies_items, list_items(:movies_item)
    assert_not_includes books_items, list_items(:movies_item)
  end

  test "should work with different polymorphic types" do
    books_item = list_items(:books_item)
    movies_item = list_items(:movies_item)
    music_item = list_items(:music_item)
    games_item = list_items(:games_item)

    assert_equal "Books::Book", books_item.listable_type
    assert_equal "Movies::Movie", movies_item.listable_type
    assert_equal "Music::Album", music_item.listable_type
    assert_equal "Games::Game", games_item.listable_type
  end

  test "list should have list_items association" do
    list = lists(:basic_list)
    assert_includes list.list_items, list_items(:basic_item)
    assert_includes list.list_items, list_items(:second_item)
  end

  test "destroying list should destroy associated list_items" do
    list = lists(:basic_list)
    item_count = list.list_items.count
    assert item_count > 0

    list.destroy
    assert_equal 0, ListItem.where(list: list).count
  end
end

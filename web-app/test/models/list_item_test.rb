# == Schema Information
#
# Table name: list_items
#
#  id            :bigint           not null, primary key
#  listable_type :string
#  metadata      :jsonb
#  position      :integer
#  verified      :boolean          default(FALSE), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  list_id       :bigint           not null
#  listable_id   :bigint
#
# Indexes
#
#  index_list_items_on_list_and_listable_unique  (list_id,listable_type,listable_id) UNIQUE
#  index_list_items_on_list_id                   (list_id)
#  index_list_items_on_list_id_and_position      (list_id,position)
#  index_list_items_on_listable                  (listable_type,listable_id)
#  index_list_items_on_verified                  (verified)
#  index_list_items_on_verified_and_listable_id  (verified,listable_id)
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

  test "should allow listable to be nil" do
    item = list_items(:basic_item)
    item.listable = nil
    assert item.valid?
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
    # Create item with same listable but different list (both Music::Albums::List)
    # basic_item is thriller in music_albums_list, so we can add it to nme_albums
    new_item = ListItem.new(
      list: lists(:nme_albums),
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
    list = lists(:music_albums_list)
    list_items = list.list_items.ordered

    # Should have at least 2 items with different positions
    assert list_items.count >= 2
    assert_equal 1, list_items.first.position
    assert_equal 2, list_items.second.position
  end

  test "by_list scope should return items for specific list" do
    list = lists(:music_albums_list)
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
    music_albums_item = list_items(:music_albums_item)
    music_songs_item = list_items(:music_songs_item)
    games_item = list_items(:games_item)

    assert_equal "Books::Book", books_item.listable_type
    assert_equal "Movies::Movie", movies_item.listable_type
    assert_equal "Music::Album", music_albums_item.listable_type
    assert_equal "Music::Song", music_songs_item.listable_type
    assert_equal "Games::Game", games_item.listable_type
  end

  test "list should have list_items association" do
    list = lists(:music_albums_list)
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

  test "with_listable scope should return items that have listable association" do
    items_with_listable = ListItem.with_listable

    # All existing fixtures should have listable associations
    assert_includes items_with_listable, list_items(:basic_item)
    assert_includes items_with_listable, list_items(:second_item)
    assert_includes items_with_listable, list_items(:books_item)
  end

  test "without_listable scope should return items without listable association" do
    items_without_listable = ListItem.without_listable

    # Should include the unverified fixtures that have no listable
    assert_equal 2, items_without_listable.count
    assert_includes items_without_listable, list_items(:unverified_book)
    assert_includes items_without_listable, list_items(:unverified_album)

    # Should not include items with listable associations
    assert_not_includes items_without_listable, list_items(:basic_item)

    # Create another unverified item
    unverified_item = ListItem.create!(
      list: lists(:basic_list),
      metadata: {title: "Another Unverified Book", author: "Unknown Author"}
    )

    items_without_listable = ListItem.without_listable
    assert_includes items_without_listable, unverified_item
    assert_equal 3, items_without_listable.count
  end

  test "verified scope should return verified items" do
    # Should include the verified fixture
    verified_items = ListItem.verified
    assert_equal 1, verified_items.count
    assert_includes verified_items, list_items(:verified_item)

    # Mark another item as verified
    item = list_items(:basic_item)
    item.update!(verified: true)

    verified_items = ListItem.verified
    assert_includes verified_items, item
    assert_includes verified_items, list_items(:verified_item)
    assert_equal 2, verified_items.count
  end

  test "unverified scope should return unverified items" do
    unverified_items = ListItem.unverified

    # Most items should be unverified by default (except verified_item fixture)
    assert_includes unverified_items, list_items(:basic_item)
    assert_includes unverified_items, list_items(:second_item)
    assert_includes unverified_items, list_items(:unverified_book)
    assert_includes unverified_items, list_items(:unverified_album)

    # Should not include the verified fixture
    assert_not_includes unverified_items, list_items(:verified_item)

    # Mark an item as verified
    item = list_items(:basic_item)
    item.update!(verified: true)

    unverified_items = ListItem.unverified
    assert_not_includes unverified_items, item
    assert_not_includes unverified_items, list_items(:verified_item)
  end

  test "should create unverified item with metadata only" do
    unverified_item = ListItem.create!(
      list: lists(:basic_list),
      metadata: {
        title: "The Great Gatsby",
        author: "F. Scott Fitzgerald",
        year: 1925
      }
    )

    assert unverified_item.valid?
    assert_nil unverified_item.listable
    assert_equal false, unverified_item.verified
    assert_equal "The Great Gatsby", unverified_item.metadata["title"]
    assert_equal "F. Scott Fitzgerald", unverified_item.metadata["author"]
    assert_equal 1925, unverified_item.metadata["year"]
  end

  test "should allow duplicate prevention to work with nil listable_id" do
    # Create two unverified items - should be allowed since listable_id is nil
    item1 = ListItem.create!(
      list: lists(:basic_list),
      metadata: {title: "Book 1", author: "Author 1"}
    )

    item2 = ListItem.create!(
      list: lists(:basic_list),
      metadata: {title: "Book 2", author: "Author 2"}
    )

    assert item1.valid?
    assert item2.valid?
    assert_nil item1.listable_id
    assert_nil item2.listable_id
  end

  # Metadata JSONB parsing tests
  test "should parse metadata JSON string to hash on save" do
    json_string = '{"title": "Test Album", "artists": ["Test Artist"], "rank": 1}'
    item = ListItem.create!(
      list: lists(:basic_list),
      metadata: json_string
    )

    assert item.metadata.is_a?(Hash)
    assert_equal "Test Album", item.metadata["title"]
    assert_equal ["Test Artist"], item.metadata["artists"]
    assert_equal 1, item.metadata["rank"]
  end

  test "should parse metadata JSON string on update" do
    item = list_items(:basic_item)
    json_string = '{"title": "Updated Title", "rank": 99}'

    item.update!(metadata: json_string)
    item.reload

    assert item.metadata.is_a?(Hash)
    assert_equal "Updated Title", item.metadata["title"]
    assert_equal 99, item.metadata["rank"]
  end

  test "should accept metadata as hash directly" do
    item = ListItem.create!(
      list: lists(:basic_list),
      metadata: {title: "Direct Hash", artists: ["Artist"]}
    )

    assert item.metadata.is_a?(Hash)
    assert_equal "Direct Hash", item.metadata["title"]
  end

  test "should reject invalid JSON string for metadata" do
    item = ListItem.new(
      list: lists(:basic_list),
      metadata: "not valid json {"
    )

    assert_not item.valid?
    assert item.errors[:metadata].any? { |e| e.include?("must be valid JSON") }
  end

  test "should allow blank metadata" do
    item = ListItem.new(
      list: lists(:basic_list),
      metadata: nil
    )

    assert item.valid?
  end

  test "should allow empty string metadata" do
    item = ListItem.new(
      list: lists(:basic_list),
      metadata: ""
    )

    assert item.valid?
  end

  test "should parse complex nested JSON metadata" do
    json_string = <<~JSON
      {
        "rank": 79,
        "title": "Jesus Christ Superstar",
        "artists": ["Various Artists"],
        "release_year": null,
        "mb_artist_ids": ["980ee2d8-2ee9-407b-b48e-48360fbc7437"],
        "mb_artist_names": ["Andrew Lloyd Webber"],
        "mb_release_year": 1972,
        "musicbrainz_match": true,
        "mb_release_group_id": "4dcde40f-63e1-3fa6-87ed-8ef10c3157df",
        "mb_release_group_name": "Jesus Christ Superstar",
        "manual_musicbrainz_link": true
      }
    JSON

    item = ListItem.create!(
      list: lists(:basic_list),
      metadata: json_string
    )

    assert item.metadata.is_a?(Hash)
    assert_equal 79, item.metadata["rank"]
    assert_equal "Jesus Christ Superstar", item.metadata["title"]
    assert_equal ["Various Artists"], item.metadata["artists"]
    assert_nil item.metadata["release_year"]
    assert_equal 1972, item.metadata["mb_release_year"]
    assert_equal true, item.metadata["musicbrainz_match"]
  end
end

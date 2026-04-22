# == Schema Information
#
# Table name: user_list_items
#
#  id            :bigint           not null, primary key
#  completed_on  :date
#  listable_type :string           not null
#  position      :integer          not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  listable_id   :bigint           not null
#  user_list_id  :bigint           not null
#
# Indexes
#
#  index_user_list_items_on_list_and_listable_unique       (user_list_id,listable_type,listable_id) UNIQUE
#  index_user_list_items_on_listable                       (listable_type,listable_id)
#  index_user_list_items_on_user_list_id                   (user_list_id)
#  index_user_list_items_on_user_list_id_and_completed_on  (user_list_id,completed_on)
#  index_user_list_items_on_user_list_id_and_position      (user_list_id,position)
#
# Foreign Keys
#
#  fk_rails_...  (user_list_id => user_lists.id)
#
require "test_helper"

class UserListItemTest < ActiveSupport::TestCase
  setup do
    @list = user_lists(:regular_user_music_albums_favorites)
    @album = music_albums(:wish_you_were_here)
  end

  test "valid fixture" do
    assert user_list_items(:regular_user_fav_album_1).valid?
  end

  test "set_position appends at end on create" do
    max_before = @list.user_list_items.maximum(:position)
    item = @list.user_list_items.create!(listable: @album)
    assert_equal max_before + 1, item.position
  end

  test "set_position starts at 1 for empty list" do
    empty_list = Music::Songs::UserList.create!(user: users(:editor_user), name: "New Songs List", list_type: :favorites)
    item = empty_list.user_list_items.create!(listable: music_songs(:time))
    assert_equal 1, item.position
  end

  test "set_position honors explicitly provided position" do
    item = @list.user_list_items.create!(listable: @album, position: 99)
    assert_equal 99, item.position
  end

  test "shift_positions_up after destroy" do
    items = @list.user_list_items.ordered.to_a
    middle = items[1]
    middle.destroy
    new_positions = @list.user_list_items.ordered.pluck(:position)
    assert_equal [1, 2], new_positions
  end

  test "uniqueness of listable within a list" do
    existing = @list.user_list_items.ordered.first
    dup = @list.user_list_items.build(listable: existing.listable)
    assert_not dup.valid?
    assert dup.errors[:listable_id].any?
  end

  test "listable_type must match user_list listable_class" do
    item = @list.user_list_items.build(listable: music_songs(:time))
    assert_not item.valid?
    assert item.errors[:listable_type].any?
  end

  test "listable_type valid when matching" do
    item = @list.user_list_items.build(listable: music_albums(:wish_you_were_here))
    assert item.valid?
  end

  test "touches user_list on save" do
    list_touched_at = @list.updated_at
    travel 1.minute do
      @list.user_list_items.create!(listable: @album)
      assert @list.reload.updated_at > list_touched_at
    end
  end

  test "ordered scope orders by position" do
    items = @list.user_list_items.ordered.to_a
    assert_equal items.map(&:position).sort, items.map(&:position)
  end

  test "user through user_list" do
    item = user_list_items(:regular_user_fav_album_1)
    assert_equal users(:regular_user), item.user
  end
end

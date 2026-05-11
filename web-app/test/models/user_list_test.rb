# == Schema Information
#
# Table name: user_lists
#
#  id          :bigint           not null, primary key
#  description :text
#  list_type   :integer          not null
#  name        :string           not null
#  position    :integer
#  public      :boolean          default(FALSE), not null
#  type        :string           not null
#  view_mode   :integer          default("default_view"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint           not null
#
# Indexes
#
#  index_user_lists_on_public            (public) WHERE (public = true)
#  index_user_lists_on_user_id           (user_id)
#  index_user_lists_on_user_id_and_type  (user_id,type)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
require "test_helper"

class UserListTest < ActiveSupport::TestCase
  setup do
    @user = users(:regular_user)
    @list = user_lists(:regular_user_music_albums_favorites)
    @custom_list = user_lists(:regular_user_custom_albums)
  end

  test "valid fixture" do
    assert @list.valid?
  end

  test "requires name" do
    @list.name = nil
    assert_not @list.valid?
    assert_includes @list.errors[:name], "can't be blank"
  end

  test "requires list_type" do
    list = Music::Albums::UserList.new(user: @user, name: "Test")
    list.list_type = nil
    assert_not list.valid?
  end

  test "requires user" do
    list = Music::Albums::UserList.new(name: "Test", list_type: :favorites)
    assert_not list.valid?
    assert_includes list.errors[:user], "must exist"
  end

  test "default? returns true for non-custom list" do
    assert @list.default?
  end

  test "default? returns false for custom list" do
    assert_not @custom_list.default?
  end

  test "one_default_per_type_per_user prevents duplicate default" do
    dup = Music::Albums::UserList.new(user: @user, name: "Another Favs", list_type: :favorites)
    assert_not dup.valid?
    assert dup.errors[:list_type].any?
  end

  test "one_default_per_type_per_user allows multiple custom lists" do
    another_custom = Music::Albums::UserList.new(user: @user, name: "Another Custom", list_type: :custom)
    assert another_custom.valid?
  end

  test "one_default_per_type_per_user allows same default list_type for different user" do
    other_user = users(:editor_user)
    list = Music::Albums::UserList.new(user: other_user, name: "Favorite Albums", list_type: :favorites)
    assert list.valid?
  end

  test "list_type cannot change after create" do
    @list.list_type = :listened
    assert_not @list.valid?
    assert @list.errors[:list_type].any?
  end

  test "base class abstract methods raise NotImplementedError" do
    assert_raises(NotImplementedError) { UserList.default_list_types }
    assert_raises(NotImplementedError) { UserList.listable_class }
    assert_raises(NotImplementedError) { UserList.default_list_name_for(:favorites) }
  end

  test "default_subclasses returns 4 subclasses" do
    assert_equal 4, UserList.default_subclasses.size
    assert_includes UserList.default_subclasses, Music::Albums::UserList
    assert_includes UserList.default_subclasses, Music::Songs::UserList
    assert_includes UserList.default_subclasses, Games::UserList
    assert_includes UserList.default_subclasses, Movies::UserList
  end

  test "public_lists scope" do
    assert_includes UserList.public_lists, @custom_list
    assert_not_includes UserList.public_lists, @list
  end

  test "owned_by scope" do
    assert_includes UserList.owned_by(@user), @list
    assert_not_includes UserList.owned_by(users(:editor_user)), @list
  end

  test "destroying a list destroys its items" do
    list = @list
    assert list.user_list_items.exists?
    assert_difference "UserListItem.count", -3 do
      list.destroy
    end
  end

  test "reorder_items! updates positions in given order" do
    items = @list.user_list_items.ordered.to_a
    reversed_ids = items.map(&:listable_id).reverse
    @list.reorder_items!(reversed_ids)
    reloaded = @list.user_list_items.ordered.pluck(:listable_id)
    assert_equal reversed_ids, reloaded
  end

  test "reorder_items! raises on id set mismatch" do
    assert_raises(ArgumentError) do
      @list.reorder_items!([99_999_999])
    end
  end

  test "reorder_items! is atomic" do
    items = @list.user_list_items.ordered.to_a
    original_ids = items.map(&:listable_id)
    assert_raises(ArgumentError) do
      @list.reorder_items!(original_ids + [99_999_999])
    end
    reloaded = @list.user_list_items.ordered.pluck(:listable_id)
    assert_equal original_ids, reloaded
  end

  test "view_mode enum" do
    @list.view_mode = :grid_view
    @list.save!
    assert @list.grid_view?
  end

  test "view_mode defaults to default_view on new records" do
    list = Music::Albums::UserList.new(user: @user, name: "Fresh", list_type: :custom)
    assert list.default_view?
  end

  test "view_mode defaults to default_view after save" do
    list = Music::Albums::UserList.create!(user: users(:editor_user), name: "Persisted", list_type: :favorites)
    assert list.reload.default_view?
  end

  test "items association returns the underlying listables" do
    assert_includes @list.items, music_albums(:dark_side_of_the_moon)
  end

  test "list_type_icons defaults to {} on the abstract base" do
    assert_equal({}, UserList.list_type_icons)
  end

  test "after_commit touches user on create" do
    user = users(:editor_user)
    user.touch(time: 1.hour.ago)
    before = user.reload.updated_at
    travel 1.minute do
      Music::Albums::UserList.create!(user: user, name: "Tracker", list_type: :custom)
      assert user.reload.updated_at > before
    end
  end

  test "after_commit touches user on update" do
    before = @list.user.reload.updated_at
    travel 1.minute do
      @list.update!(name: "Renamed Favorites")
      assert @list.user.reload.updated_at > before
    end
  end

  test "after_commit touches user on destroy" do
    user = @custom_list.user
    user_list_items(:regular_user_custom_album_1).destroy
    before = user.reload.updated_at
    travel 1.minute do
      @custom_list.destroy
      assert user.reload.updated_at > before
    end
  end
end

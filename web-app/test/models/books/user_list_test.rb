require "test_helper"

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
module Books
  class UserListTest < ActiveSupport::TestCase
    test "default_list_types" do
      assert_equal [:favorites, :read, :reading, :want_to_read], Books::UserList.default_list_types
    end

    test "listable_class" do
      assert_equal Books::Book, Books::UserList.listable_class
    end

    test "list_type enum uses the new-app convention, not the legacy integers" do
      assert_equal({"favorites" => 0, "read" => 1, "reading" => 2, "want_to_read" => 3, "custom" => 4},
        Books::UserList.list_types.to_h)
    end

    test "default_list_name_for returns the legacy display name for each default type" do
      assert_equal "My Favorite Books", Books::UserList.default_list_name_for(:favorites)
      assert_equal "Books I've Read", Books::UserList.default_list_name_for(:read)
      assert_equal "Books I'm Reading", Books::UserList.default_list_name_for(:reading)
      assert_equal "Books I Want to Read", Books::UserList.default_list_name_for(:want_to_read)
    end

    test "default_list_name_for raises on unknown list_type" do
      assert_raises(KeyError) { Books::UserList.default_list_name_for(:bogus) }
    end

    test "completed_on is enabled only for the read list" do
      assert_equal [:read], Books::UserList.completed_on_list_types

      user = users(:regular_user)
      read_list = Books::UserList.create!(user: user, name: "Books I've Read", list_type: :read)
      reading_list = Books::UserList.create!(user: user, name: "Books I'm Reading", list_type: :reading)

      assert read_list.completed_on_enabled?
      assert_not reading_list.completed_on_enabled?
    end

    test "ranking_configuration_class" do
      assert_equal Books::RankingConfiguration, Books::UserList.ranking_configuration_class
    end

    test "list_type_icons covers every non-custom type and excludes custom" do
      assert_equal [:favorites, :read, :reading, :want_to_read], Books::UserList.list_type_icons.keys
      assert_not_includes Books::UserList.list_type_icons.keys, :custom
    end

    test "only accepts Books::Book as a listable" do
      user = users(:regular_user)
      list = Books::UserList.create!(user: user, name: "My Favorite Books", list_type: :favorites)
      item = UserListItem.new(user_list: list, listable: music_albums(:dark_side_of_the_moon))

      assert_not item.valid?
      assert_includes item.errors[:listable_type], "Music::Album is not compatible with Books::UserList"
    end

    test "is deliberately excluded from DEFAULT_SUBCLASSES and DOMAIN_SUBCLASSES" do
      assert_not_includes UserList::DEFAULT_SUBCLASSES, "Books::UserList"
      assert_equal [], UserList.subclasses_for(:books)
    end
  end
end

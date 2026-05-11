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

module Games
  class UserListTest < ActiveSupport::TestCase
    test "default_list_types" do
      expected = [:favorites, :played, :beaten, :want_to_play, :currently_playing]
      assert_equal expected, Games::UserList.default_list_types
    end

    test "listable_class" do
      assert_equal Games::Game, Games::UserList.listable_class
    end

    test "default_list_name_for" do
      assert_equal "Favorite Games", Games::UserList.default_list_name_for(:favorites)
      assert_equal "Games I've Played", Games::UserList.default_list_name_for(:played)
      assert_equal "Games I've Beaten", Games::UserList.default_list_name_for(:beaten)
      assert_equal "Games I Want to Play", Games::UserList.default_list_name_for(:want_to_play)
      assert_equal "Games I'm Currently Playing", Games::UserList.default_list_name_for(:currently_playing)
    end

    test "list_type enum keys" do
      assert_equal %w[favorites played beaten want_to_play currently_playing custom], Games::UserList.list_types.keys
    end

    test "list_type_icons covers each non-custom list_type" do
      icons = Games::UserList.list_type_icons
      assert_equal "heart", icons[:favorites]
      assert_equal "check", icons[:played]
      assert_equal "trophy", icons[:beaten]
      assert_equal "gamepad-2", icons[:currently_playing]
      assert_equal "bookmark", icons[:want_to_play]
      refute icons.key?(:custom)
    end
  end
end

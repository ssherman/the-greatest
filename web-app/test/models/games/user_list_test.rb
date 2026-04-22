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
  end
end

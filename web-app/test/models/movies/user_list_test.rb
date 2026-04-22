require "test_helper"

module Movies
  class UserListTest < ActiveSupport::TestCase
    test "default_list_types" do
      assert_equal [:favorites, :watched, :want_to_watch], Movies::UserList.default_list_types
    end

    test "listable_class" do
      assert_equal Movies::Movie, Movies::UserList.listable_class
    end

    test "default_list_name_for" do
      assert_equal "Favorite Movies", Movies::UserList.default_list_name_for(:favorites)
      assert_equal "Movies I've Watched", Movies::UserList.default_list_name_for(:watched)
      assert_equal "Movies I Want to Watch", Movies::UserList.default_list_name_for(:want_to_watch)
    end

    test "list_type enum keys" do
      assert_equal %w[favorites watched want_to_watch custom], Movies::UserList.list_types.keys
    end
  end
end

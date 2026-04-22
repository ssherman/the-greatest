require "test_helper"

module Music
  module Albums
    class UserListTest < ActiveSupport::TestCase
      test "default_list_types" do
        assert_equal [:favorites, :listened, :want_to_listen], Music::Albums::UserList.default_list_types
      end

      test "listable_class" do
        assert_equal Music::Album, Music::Albums::UserList.listable_class
      end

      test "default_list_name_for returns display name for each default type" do
        assert_equal "Favorite Albums", Music::Albums::UserList.default_list_name_for(:favorites)
        assert_equal "Albums I've Listened To", Music::Albums::UserList.default_list_name_for(:listened)
        assert_equal "Albums I Want to Listen To", Music::Albums::UserList.default_list_name_for(:want_to_listen)
      end

      test "default_list_name_for raises on unknown list_type" do
        assert_raises(KeyError) { Music::Albums::UserList.default_list_name_for(:bogus) }
      end

      test "list_type enum has favorites, listened, want_to_listen, custom" do
        assert_equal %w[favorites listened want_to_listen custom], Music::Albums::UserList.list_types.keys
      end
    end
  end
end

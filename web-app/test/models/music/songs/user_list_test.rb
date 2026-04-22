require "test_helper"

module Music
  module Songs
    class UserListTest < ActiveSupport::TestCase
      test "default_list_types" do
        assert_equal [:favorites], Music::Songs::UserList.default_list_types
      end

      test "listable_class" do
        assert_equal Music::Song, Music::Songs::UserList.listable_class
      end

      test "default_list_name_for" do
        assert_equal "Favorite Songs", Music::Songs::UserList.default_list_name_for(:favorites)
      end

      test "list_type enum has favorites, custom" do
        assert_equal %w[favorites custom], Music::Songs::UserList.list_types.keys
      end
    end
  end
end

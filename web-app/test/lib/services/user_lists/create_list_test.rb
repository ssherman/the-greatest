require "test_helper"

module Services
  module UserLists
    class CreateListTest < ActiveSupport::TestCase
      setup { @user = users(:regular_user) }

      test "creates a custom list of the given class" do
        result = CreateList.call(user: @user, klass: ::Music::Albums::UserList, name: "Mine")

        assert result.success?
        list = result.data[:list]
        assert_instance_of ::Music::Albums::UserList, list
        assert_equal "custom", list.list_type
        assert_equal false, list.public
      end

      test "strips the name and stores a blank description as nil" do
        result = CreateList.call(user: @user, klass: ::Music::Albums::UserList, name: "  Mine  ", description: "   ")

        assert_equal "Mine", result.data[:list].name
        assert_nil result.data[:list].description
      end

      test "fails on a blank, 101-character or NUL name" do
        ["  ", "a" * 101, "a\u0000b"].each do |name|
          assert_no_difference "UserList.count" do
            result = CreateList.call(user: @user, klass: ::Music::Albums::UserList, name: name)
            refute result.success?
          end
        end
      end

      test "fails on an invalid description" do
        result = CreateList.call(user: @user, klass: ::Music::Albums::UserList, name: "Ok", description: "a" * 1_001)

        refute result.success?
      end
    end
  end
end

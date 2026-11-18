require "test_helper"

module Services
  module UserLists
    class UpdateListTest < ActiveSupport::TestCase
      test "renames a custom list" do
        list = user_lists(:regular_user_custom_albums)

        result = UpdateList.call(list: list, attrs: {name: "Renamed"})

        assert result.success?
        assert_equal "Renamed", list.reload.name
      end

      test "refuses to rename a default list but saves its description and public" do
        list = user_lists(:regular_user_books_read)

        result = UpdateList.call(list: list, attrs: {name: "X"})
        refute result.success?
        assert_equal ["A default list cannot be renamed"], result.errors
        refute_equal "X", list.reload.name

        result = UpdateList.call(list: list, attrs: {description: "d", public: true})
        assert result.success?
        assert_equal ["d", true], [list.reload.description, list.public]
      end
    end
  end
end

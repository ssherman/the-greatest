require "test_helper"

module LegacyBooks
  class RecordTest < ActiveSupport::TestCase
    test "Record is an abstract read-only base" do
      assert LegacyBooks::Record.abstract_class?
    end

    test "legacy models point at the legacy tables" do
      assert_equal "authors", LegacyBooks::Author.table_name
      assert_equal "languages", LegacyBooks::Language.table_name
      assert_equal "list_cons", LegacyBooks::ListCon.table_name
      assert_equal "list_con_lists", LegacyBooks::ListConList.table_name
      assert_equal "user_lists", LegacyBooks::UserList.table_name
      assert_equal "user_list_books", LegacyBooks::UserListBook.table_name
    end
  end
end

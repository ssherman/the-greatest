require "test_helper"

module Mcp
  class ToolDirectoryTest < ActiveSupport::TestCase
    test "the public books directory is every catalogue tool plus find_book" do
      catalog = Mcp::Catalog.for(document: :public, domain: :books)
      entries = Mcp::ToolDirectory.entries(document: :public, domain: :books)

      assert_equal catalog.operations.map(&:tool_name) + ["find_book"], entries.map(&:name)
      assert_equal 27, entries.size
    end

    test "the admin books directory is the 22 admin tools, eight destructive" do
      entries = Mcp::ToolDirectory.entries(document: :admin, domain: :books)

      assert_equal 22, entries.size
      assert_equal %w[delete_admin_category merge_author merge_book merge_categories merge_duplicate_candidate reject_match_decision_link untag_author untag_book],
        entries.select(&:destructive).map(&:name).sort
    end

    test "a host with no API operations has an empty directory" do
      assert_equal [], Mcp::ToolDirectory.entries(document: :public, domain: :music)
    end

    test "each entry carries the tool's own title and description" do
      catalog = Mcp::Catalog.for(document: :public, domain: :books)
      get_book = Mcp::ToolDirectory.entries(document: :public, domain: :books).find { |entry| entry.name == "get_book" }

      assert_equal catalog.fetch("getBook").description, get_book.description
      assert_equal catalog.fetch("getBook").title, get_book.title
      assert_equal false, get_book.destructive
    end

    test "find_book is the only composite on public books and admin has none" do
      public_entries = Mcp::ToolDirectory.entries(document: :public, domain: :books)

      assert_equal ["find_book"], public_entries.select(&:composite).map(&:name)
      assert_equal 26, public_entries.count { |entry| !entry.composite }
      assert_empty Mcp::ToolDirectory.entries(document: :admin, domain: :books).select(&:composite)
    end

    test "a composite's destructive flag is its derived destructive hint" do
      find_book = Mcp::ToolDirectory.entries(document: :public, domain: :books).find { |entry| entry.name == "find_book" }

      assert_equal Mcp::Sites::Books::FindBook.title, find_book.title
      assert_equal Mcp::Sites::Books::FindBook.description, find_book.description
      assert_equal false, find_book.destructive
    end

    test "public_tools? is true only for a site with a public MCP endpoint" do
      assert Mcp::ToolDirectory.public_tools?(:books)
      assert_not Mcp::ToolDirectory.public_tools?(:music)
      assert_not Mcp::ToolDirectory.public_tools?(:games)
    end
  end
end

require "test_helper"

class Services::BooksMigration::SearchSuppressionTest < ActiveSupport::TestCase
  test "suppresses SearchIndexRequest creation inside the block" do
    author = books_authors(:tolstoy)
    assert_no_difference -> { SearchIndexRequest.count } do
      Services::BooksMigration.without_search_indexing do
        author.update!(description: "changed inside block")
      end
    end
  end

  test "does not suppress outside the block" do
    author = books_authors(:tolstoy)
    assert_difference -> { SearchIndexRequest.count }, 1 do
      author.update!(description: "changed outside block")
    end
  end

  test "resets the flag even if the block raises" do
    assert_raises(RuntimeError) do
      Services::BooksMigration.without_search_indexing { raise "boom" }
    end
    refute Services::BooksMigration.search_indexing_suppressed?
  end
end

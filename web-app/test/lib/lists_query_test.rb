require "test_helper"

class ListsQueryTest < ActiveSupport::TestCase
  test "normalize_sort accepts the whitelist" do
    assert_equal "weight", ListsQuery.normalize_sort("weight")
    assert_equal "newest", ListsQuery.normalize_sort("newest")
  end

  test "normalize_sort falls back to weight for anything else" do
    assert_equal "weight", ListsQuery.normalize_sort("bogus")
    assert_equal "weight", ListsQuery.normalize_sort(nil)
    assert_equal "weight", ListsQuery.normalize_sort("'; DROP TABLE lists; --")
  end

  test "the base class refuses to run without a list type" do
    assert_raises(NotImplementedError) { ListsQuery.list_type }
  end
end

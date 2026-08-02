require "test_helper"

module Books
  class DefaultHelperTest < ActionView::TestCase
    include Books::DefaultHelper

    test "noindex when public indexing is disabled even for indexable pages" do
      Books::PublicIndexing.stubs(:enabled?).returns(false)
      @indexable = true

      assert_equal "noindex, follow", books_robots_content
    end

    test "index when public indexing is enabled and the page is indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)
      @indexable = true

      assert_equal "index, follow", books_robots_content
    end

    test "noindex when the page is not indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)
      @indexable = false

      assert_equal "noindex, follow", books_robots_content
    end

    test "noindex when the url carries a ranking configuration id" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)
      @indexable = true
      params[:ranking_configuration_id] = "8"

      assert_equal "noindex, follow", books_robots_content
    end

    test "lists path keeps the ranking configuration when one is present" do
      params[:ranking_configuration_id] = "8"

      assert_equal "/rc/8/lists", books_lists_path_with_rc
      assert_equal "/rc/8/lists/12", books_list_path_with_rc(12)
    end

    test "lists path omits the ranking configuration when there is none" do
      assert_equal "/lists", books_lists_path_with_rc
      assert_equal "/lists/12", books_list_path_with_rc(12)
    end

    test "lists path passes query options through" do
      assert_equal "/lists?sort=newest", books_lists_path_with_rc(sort: "newest")

      params[:ranking_configuration_id] = "8"
      assert_equal "/rc/8/lists?sort=newest", books_lists_path_with_rc(sort: "newest")
    end
  end
end

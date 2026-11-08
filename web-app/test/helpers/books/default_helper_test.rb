require "test_helper"

module Books
  class DefaultHelperTest < ActionView::TestCase
    include Books::DefaultHelper

    test "books_nav_current? matches the exact path" do
      request.path = "/authors"

      assert books_nav_current?("/authors")
      assert_not books_nav_current?("/")
    end

    test "books_nav_current? treats a paged listing as the same page" do
      request.path = "/authors/page/3"

      assert books_nav_current?("/authors")
    end

    test "books_nav_current? treats a paged root as the root" do
      request.path = "/page/2"

      assert books_nav_current?("/")
    end

    test "books_nav_current? does not match a page below the link" do
      request.path = "/lists/463"

      assert_not books_nav_current?("/lists")
    end

    test "books_nav_link marks the current page in the drawer" do
      request.path = "/authors"

      assert_includes books_nav_link("Authors", "/authors", :vertical), 'aria-current="page"'
    end

    test "books_nav_link leaves other drawer links unmarked" do
      request.path = "/authors"

      assert_not_includes books_nav_link("News", "/news", :vertical), "aria-current"
    end

    test "books_nav_link does not mark the desktop bar" do
      request.path = "/authors"

      assert_not_includes books_nav_link("Authors", "/authors", :horizontal), "aria-current"
    end

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

require "test_helper"

module Games
  class DefaultHelperTest < ActionView::TestCase
    include Games::DefaultHelper

    test "index by default when no page sets indexable" do
      assert_equal "index, follow", games_robots_content
    end

    test "index when the page is explicitly indexable" do
      @indexable = true

      assert_equal "index, follow", games_robots_content
    end

    test "noindex when the page is not indexable" do
      @indexable = false

      assert_equal "noindex, follow", games_robots_content
    end

    test "noindex when the url carries a ranking configuration id" do
      @indexable = true
      params[:ranking_configuration_id] = "4"

      assert_equal "noindex, follow", games_robots_content
    end

    test "lists path keeps the ranking configuration when one is present" do
      params[:ranking_configuration_id] = "4"

      assert_equal "/rc/4/lists", games_lists_path_with_rc
    end

    test "lists path omits the ranking configuration when there is none" do
      assert_equal "/lists", games_lists_path_with_rc
    end

    test "lists path passes query options through" do
      assert_equal "/lists?sort=newest", games_lists_path_with_rc(sort: "newest")
    end
  end
end

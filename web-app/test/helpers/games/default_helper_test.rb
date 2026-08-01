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
  end
end
